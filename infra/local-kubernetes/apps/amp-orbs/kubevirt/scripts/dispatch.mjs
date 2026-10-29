#!/usr/bin/env node
// Handles one `amp orb provider` job: each orb is a KubeVirt VM booted from the
// orb containerDisk, with /home/user on a PVC disk and ORB_TOKEN on a Secret disk.
// Pausing halts the VM and keeps its PVC.
import { readFileSync } from 'node:fs'

const { ORB_OPERATION, ORB_ID, ORB_TOKEN, AMP_URL, ORB_VM_IMAGE } = process.env
const serviceAccount = '/var/run/secrets/kubernetes.io/serviceaccount'
const namespace = readFileSync(`${serviceAccount}/namespace`, 'utf8').trim()
const token = readFileSync(`${serviceAccount}/token`, 'utf8').trim()
const api = `https://${process.env.KUBERNETES_SERVICE_HOST}:${process.env.KUBERNETES_SERVICE_PORT}`

if (!/^[a-z0-9]([-a-z0-9]{0,50}[a-z0-9])?$/.test(ORB_ID ?? '')) {
	throw new Error(`unexpected ORB_ID: ${ORB_ID}`)
}

const names = { vm: ORB_ID, home: `${ORB_ID}-home`, env: `${ORB_ID}-env` }
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

function orbVM() {
	return {
		apiVersion: 'kubevirt.io/v1',
		kind: 'VirtualMachine',
		metadata: { name: names.vm, labels },
		spec: {
			runStrategy: 'Always',
			template: {
				metadata: { labels },
				spec: {
					domain: {
						cpu: { cores: 4 },
						memory: { guest: '8Gi' },
						firmware: {
							kernelBoot: {
								kernelArgs: 'root=LABEL=orb-root rw console=ttyS0',
								container: { image: ORB_VM_IMAGE, kernelPath: '/boot/vmlinuz', initrdPath: '/boot/initrd.img' },
							},
						},
						devices: {
							disks: [
								{ name: 'root', disk: { bus: 'virtio' } },
								{ name: 'home', serial: 'home', disk: { bus: 'virtio' } },
								{ name: 'orbenv', serial: 'orbenv', disk: { bus: 'virtio' } },
							],
							interfaces: [{ name: 'default', masquerade: {} }],
						},
					},
					networks: [{ name: 'default', pod: {} }],
					terminationGracePeriodSeconds: 30,
					volumes: [
						{ name: 'root', containerDisk: { image: ORB_VM_IMAGE } },
						{ name: 'home', persistentVolumeClaim: { claimName: names.home } },
						{ name: 'orbenv', secret: { secretName: names.env } },
					],
				},
			},
		},
	}
}

async function spawn() {
	// Every spawn carries a fresh ORB_TOKEN, which the VM reads from its Secret disk at boot.
	await halt()
	const env = { ORB_TOKEN, ...(AMP_URL && { AMP_URL }) }
	const secret = { metadata: { name: names.env, labels }, type: 'Opaque', stringData: env }
	if (await request('GET', core('secrets', names.env))) await request('PUT', core('secrets', names.env), secret)
	else await request('POST', core('secrets'), secret)
	if (!(await request('GET', core('persistentvolumeclaims', names.home)))) {
		await request('POST', core('persistentvolumeclaims'), {
			metadata: { name: names.home, labels },
			spec: {
				accessModes: ['ReadWriteOnce'],
				storageClassName: 'orb-storage',
				resources: { requests: { storage: '30Gi' } },
			},
		})
	}
	if (await request('GET', kubevirt('virtualmachines', names.vm))) await setRunStrategy('Always')
	else await request('POST', kubevirt('virtualmachines'), orbVM())
	const running = await waitFor(async () => (await vmi())?.status?.phase === 'Running', 240)
	console.log(running ? `orb ${ORB_ID} running` : `orb ${ORB_ID} still starting`)
}

async function remove() {
	await request('DELETE', kubevirt('virtualmachines', names.vm))
	await waitFor(async () => !(await vmi()), 120)
	await request('DELETE', core('persistentvolumeclaims', names.home))
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
