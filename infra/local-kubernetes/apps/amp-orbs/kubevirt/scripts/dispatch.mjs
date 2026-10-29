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

const names = { vm: ORB_ID, state: `${ORB_ID}-state`, swap: `${ORB_ID}-swap`, env: `${ORB_ID}-env` }
// The state PVC records which image last booted on it; only that image can resume.
const bootedImage = 'amp.ampcode.com/booted-image'
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
const kubevirt = (kind, name = '') => `/apis/kubevirt.io/v1/namespaces/${namespace}/${kind}${name && `/${name}`}`
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function waitFor(check, seconds) {
	for (let i = 0; i < seconds; i++) {
		if (await check()) return true
		await sleep(1000)
	}
	return false
}

const vmi = () => request('GET', kubevirt('virtualmachineinstances', names.vm))

async function setRunStrategy(runStrategy) {
	await request('PATCH', kubevirt('virtualmachines', names.vm), { spec: { runStrategy } }, 'application/merge-patch+json')
}

async function halt() {
	if (!(await request('GET', kubevirt('virtualmachines', names.vm)))) return
	await setRunStrategy('Halted')
	if (!(await waitFor(async () => !(await vmi()), 120))) throw new Error(`orb ${ORB_ID} did not stop`)
}

function orbVM(resume) {
	const kernelArgs = ['root=LABEL=orb-root ro', 'console=ttyS0', 'quiet', `orb.image=${ORB_VM_IMAGE.split('@').pop()}`]
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
								container: { image: ORB_VM_IMAGE, kernelPath: '/boot/vmlinuz', initrdPath: '/boot/initrd.img' },
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
						{ name: 'root', containerDisk: { image: ORB_VM_IMAGE } },
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
	await request('DELETE', kubevirt('virtualmachines', names.vm))
	const gone = async () => !(await vmi()) && !(await request('GET', kubevirt('virtualmachines', names.vm)))
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

async function spawn() {
	// Every spawn carries a fresh ORB_TOKEN, which the VM reads from its Secret disk at boot
	// or after resuming, and recreates the VM so it runs the current spec; its PVCs stay.
	await removeVM()
	const env = { ORB_TOKEN, ...(AMP_URL && { AMP_URL }) }
	const secret = { metadata: { name: names.env, labels }, type: 'Opaque', stringData: env }
	if (await request('GET', core('secrets', names.env))) await request('PUT', core('secrets', names.env), secret)
	else await request('POST', core('secrets'), secret)
	const state = await ensureClaim(names.state, 30)
	await ensureClaim(names.swap, memory + 1)
	const resume = state.metadata.annotations?.[bootedImage] === ORB_VM_IMAGE
	await request(
		'PATCH',
		core('persistentvolumeclaims', names.state),
		{ metadata: { annotations: { [bootedImage]: ORB_VM_IMAGE } } },
		'application/merge-patch+json',
	)
	await request('POST', kubevirt('virtualmachines'), orbVM(resume))
	const running = await waitFor(async () => (await vmi())?.status?.phase === 'Running', 240)
	console.log(`orb ${ORB_ID} ${running ? 'running' : 'still starting'}, ${resume ? 'resuming' : 'booting'} ${ORB_VM_IMAGE}`)
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
