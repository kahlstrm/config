#!/usr/bin/env node
// Handles one `amp orb provider` job: each orb is a KubeVirt VM booted from the
// read-only orb containerDisk, with its changes on a state PVC, a swap PVC it
// hibernates to and ORB_TOKEN on a Secret disk. Pausing hibernates the VM and
// powers it off, so a paused orb holds no memory; the next spawn restores it.
import { readFileSync } from 'node:fs'

const { ORB_OPERATION, ORB_ID, ORB_TOKEN, AMP_URL, ORB_VM_IMAGE } = process.env
// The bench drives this script from outside the cluster with KUBE_* set.
const serviceAccount = '/var/run/secrets/kubernetes.io/serviceaccount'
const namespace = process.env.KUBE_NAMESPACE ?? readFileSync(`${serviceAccount}/namespace`, 'utf8').trim()
const token = process.env.KUBE_TOKEN ?? readFileSync(`${serviceAccount}/token`, 'utf8').trim()
const api = process.env.KUBE_API ?? `https://${process.env.KUBERNETES_SERVICE_HOST}:${process.env.KUBERNETES_SERVICE_PORT}`
const memory = 8

if (!/^[a-z0-9]([-a-z0-9]{0,50}[a-z0-9])?$/.test(ORB_ID ?? '')) {
	throw new Error(`unexpected ORB_ID: ${ORB_ID}`)
}

// Each spawn names its VM afresh: KubeVirt still cleans up after a just-stopped VMI
// and backs off on its name, which delayed an immediate resume by about 9 s.
const names = { vm: `${ORB_ID}-${Date.now().toString(36)}`, state: `${ORB_ID}-state`, swap: `${ORB_ID}-swap`, env: `${ORB_ID}-env` }
// The state PVC records which image last booted on it; only that image can resume.
const bootedImage = 'amp.ampcode.com/booted-image'
// And when the orb last paused: reclaim.mjs deletes the disks of orbs paused too long.
const pausedAt = 'amp.ampcode.com/paused-at'
const labels = { 'app.kubernetes.io/name': 'amp-orb', 'amp.ampcode.com/orb-id': ORB_ID }

async function request(method, path, body, contentType = 'application/json') {
	const response = await fetch(`${api}${path}`, {
		method,
		headers: { authorization: `Bearer ${token}`, 'content-type': contentType },
		body: body && JSON.stringify(body),
	})
	if (response.status === 404 && method !== 'POST') return null
	if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`)
	return response.json()
}

const core = (kind, name = '') => `/api/v1/namespaces/${namespace}/${kind}${name && `/${name}`}`
const apps = (kind, name = '') => `/apis/apps/v1/namespaces/${namespace}/${kind}${name && `/${name}`}`
const kubevirt = (kind, name = '') => `/apis/kubevirt.io/v1/namespaces/${namespace}/${kind}${name && `/${name}`}`
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// Polls five times a second: a halted VM is usually gone within 0.1 s, and every
// spawn waits for that before creating the new one.
async function waitFor(check, seconds) {
	for (let i = 0; i < seconds * 5; i++) {
		if (await check()) return true
		await sleep(200)
	}
	return false
}

const orbSelector = `?labelSelector=${encodeURIComponent(`amp.ampcode.com/orb-id=${ORB_ID}`)}`
const orbVMs = async () => (await request('GET', kubevirt('virtualmachines') + orbSelector)).items
const orbVMIs = async () => (await request('GET', kubevirt('virtualmachineinstances') + orbSelector)).items
const vmi = () => request('GET', kubevirt('virtualmachineinstances', names.vm))

const annotateState = (annotations) =>
	request('PATCH', core('persistentvolumeclaims', names.state), { metadata: { annotations } }, 'application/merge-patch+json')

async function halt() {
	for (const vm of await orbVMs()) {
		const patch = { spec: { runStrategy: 'Halted' } }
		await request('PATCH', kubevirt('virtualmachines', vm.metadata.name), patch, 'application/merge-patch+json')
	}
	if (!(await waitFor(async () => (await orbVMIs()).length === 0, 120))) throw new Error(`orb ${ORB_ID} did not stop`)
	await annotateState({ [pausedAt]: new Date().toISOString() })
}

function orbVM(image, resume) {
	// kvm-clock never runs backwards, so a guest restored into a new VM, whose clock
	// starts near zero, would stall for as long as it ran before the pause.
	const clock = ['clocksource=tsc', 'tsc=reliable']
	const kernelArgs = ['root=LABEL=orb-root ro', 'console=ttyS0', 'quiet', ...clock, `orb.image=${image.split('@').pop()}`]
	if (resume) kernelArgs.push('resume=/dev/disk/by-id/virtio-swap')
	return {
		apiVersion: 'kubevirt.io/v1',
		kind: 'VirtualMachine',
		metadata: { name: names.vm, labels },
		spec: {
			runStrategy: 'Always',
			template: {
				metadata: { labels },
				spec: {
					// Without it KubeVirt picks the cluster default, arm64 like the control planes.
					architecture: 'amd64',
					domain: {
						cpu: { cores: 4 },
						memory: { guest: `${memory}Gi` },
						firmware: {
							kernelBoot: {
								kernelArgs: kernelArgs.join(' '),
								container: { image, kernelPath: '/boot/vmlinuz', initrdPath: '/boot/initrd.img' },
							},
						},
						devices: {
							disks: [
								{ name: 'root', disk: { bus: 'virtio' } },
								{ name: 'state', serial: 'state', disk: { bus: 'virtio' } },
								{ name: 'swap', serial: 'swap', disk: { bus: 'virtio' } },
								{ name: 'orbenv', serial: 'orbenv', disk: { bus: 'virtio' } },
							],
							interfaces: [{ name: 'default', masquerade: {} }],
						},
					},
					networks: [{ name: 'default', pod: {} }],
					// Pausing waits while the guest writes its memory to the swap disk.
					terminationGracePeriodSeconds: 180,
					volumes: [
						{ name: 'root', containerDisk: { image } },
						{ name: 'state', persistentVolumeClaim: { claimName: names.state } },
						{ name: 'swap', persistentVolumeClaim: { claimName: names.swap } },
						{ name: 'orbenv', secret: { secretName: names.env } },
					],
				},
			},
		},
	}
}

async function removeVM() {
	for (const vm of await orbVMs()) await request('DELETE', kubevirt('virtualmachines', vm.metadata.name))
	const gone = async () => (await orbVMIs()).length === 0 && (await orbVMs()).length === 0
	if (!(await waitFor(gone, 240))) throw new Error(`orb ${ORB_ID} did not stop`)
}

async function ensureClaim(name, gibibytes) {
	const claim = await request('GET', core('persistentvolumeclaims', name))
	if (claim) return claim
	return request('POST', core('persistentvolumeclaims'), {
		metadata: { name, labels },
		spec: {
			accessModes: ['ReadWriteOnce'],
			storageClassName: 'orb-storage',
			resources: { requests: { storage: `${gibibytes}Gi` } },
		},
	})
}

// Boots the image the pre-pull DaemonSet has on every worker: its own once it has
// rolled out, its previous one until then, so no orb waits for a pull of over a
// gigabyte. ORB_VM_IMAGE, the same reference, is for the bench, which has no DaemonSet.
const prepullImage = (template) => template.spec.volumes.find((volume) => volume.name === 'orb-image')?.image?.reference

async function cachedImage() {
	const prepull = await request('GET', apps('daemonsets', 'orb-image-prepull'))
	if (!prepull) return ORB_VM_IMAGE
	const { metadata, spec, status } = prepull
	const desired = status.desiredNumberScheduled
	const current = prepullImage(spec.template)
	const pulled =
		status.observedGeneration === metadata.generation && status.updatedNumberScheduled === desired && status.numberAvailable === desired
	if (pulled) return current
	const selector = encodeURIComponent('app.kubernetes.io/name=orb-image-prepull')
	const { items } = await request('GET', `${apps('controllerrevisions')}?labelSelector=${selector}`)
	const previous = items
		.sort((a, b) => b.revision - a.revision)
		.map((revision) => prepullImage(revision.data.spec.template))
		.find((image) => image && image !== current)
	return previous ?? current
}

async function spawn() {
	// Every spawn carries a fresh ORB_TOKEN, which the VM reads from its Secret disk at boot
	// or after resuming, and recreates the VM so it runs the current spec; its PVCs stay.
	// Clear the pause time first, so reclaim.mjs leaves a waking orb's disks alone.
	await annotateState({ [pausedAt]: null })
	await removeVM()
	const env = { ORB_TOKEN, ...(AMP_URL && { AMP_URL }) }
	const secret = { metadata: { name: names.env, labels }, type: 'Opaque', stringData: env }
	if (await request('GET', core('secrets', names.env))) await request('PUT', core('secrets', names.env), secret)
	else await request('POST', core('secrets'), secret)
	const state = await ensureClaim(names.state, 30)
	await ensureClaim(names.swap, memory + 1)
	const image = await cachedImage()
	const resume = state.metadata.annotations?.[bootedImage] === image
	await annotateState({ [bootedImage]: image })
	await request('POST', kubevirt('virtualmachines'), orbVM(image, resume))
	const running = await waitFor(async () => (await vmi())?.status?.phase === 'Running', 240)
	console.log(`orb ${ORB_ID} ${running ? 'running' : 'still starting'}, ${resume ? 'resuming' : 'booting'} ${image}`)
}

async function remove() {
	await removeVM()
	await request('DELETE', core('persistentvolumeclaims', names.state))
	await request('DELETE', core('persistentvolumeclaims', names.swap))
	// Orbs from before the state disk had a home PVC instead.
	await request('DELETE', core('persistentvolumeclaims', `${ORB_ID}-home`))
	await request('DELETE', core('secrets', names.env))
}

const operations = { spawn, pause: halt, delete: remove }
if (!operations[ORB_OPERATION]) throw new Error(`unknown ORB_OPERATION: ${ORB_OPERATION}`)
// One line per job, for the orb dashboard and alerts on failed or slow jobs.
const started = Date.now()
const log = (result, error) =>
	console.log(JSON.stringify({ msg: 'orb job', operation: ORB_OPERATION, orb: ORB_ID, result, seconds: (Date.now() - started) / 1000, error }))
try {
	await operations[ORB_OPERATION]()
	log('ok')
} catch (error) {
	log('failed', String(error))
	throw error
}
