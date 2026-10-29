#!/usr/bin/env node
// Handles one `amp orb provider` job: each orb is a gVisor pod whose /home/user
// lives on a PVC, so pausing deletes the pod and keeps the PVC.
import { readFileSync } from 'node:fs'

const { ORB_OPERATION, ORB_ID, ORB_IMAGE, ORB_TOKEN, AMP_URL } = process.env
const serviceAccount = '/var/run/secrets/kubernetes.io/serviceaccount'
const namespace = readFileSync(`${serviceAccount}/namespace`, 'utf8').trim()
const token = readFileSync(`${serviceAccount}/token`, 'utf8').trim()
const api = `https://${process.env.KUBERNETES_SERVICE_HOST}:${process.env.KUBERNETES_SERVICE_PORT}`

if (!/^[a-z0-9]([-a-z0-9]{0,50}[a-z0-9])?$/.test(ORB_ID ?? '')) {
	throw new Error(`unexpected ORB_ID: ${ORB_ID}`)
}

const names = { pod: ORB_ID, home: `${ORB_ID}-home`, env: `${ORB_ID}-env` }
const labels = { 'app.kubernetes.io/name': 'amp-orb', 'amp.ampcode.com/orb-id': ORB_ID }

async function request(method, path, body) {
	const response = await fetch(`${api}${path}`, {
		method,
		headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
		body: body && JSON.stringify(body),
	})
	if (response.status === 404 && method !== 'POST') return null
	if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`)
	return response.json()
}

const core = (kind, name = '') => `/api/v1/namespaces/${namespace}/${kind}${name && `/${name}`}`
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function waitFor(check, seconds) {
	for (let i = 0; i < seconds; i++) {
		if (await check()) return true
		await sleep(1000)
	}
	return false
}

async function ensure(kind, name, body) {
	if (!(await request('GET', core(kind, name)))) await request('POST', core(kind), body)
}

async function removePod() {
	await request('DELETE', core('pods', names.pod))
	if (!(await waitFor(async () => !(await request('GET', core('pods', names.pod))), 120))) {
		throw new Error(`orb ${ORB_ID} did not stop`)
	}
}

function orbPod() {
	const home = { name: 'home', persistentVolumeClaim: { claimName: names.home } }
	return {
		metadata: { name: names.pod, labels },
		spec: {
			runtimeClassName: 'gvisor',
			automountServiceAccountToken: false,
			enableServiceLinks: false,
			terminationGracePeriodSeconds: 30,
			volumes: [home],
			// The image keeps the Amp CLI and its dotfiles in /home/user, so a new PVC starts from them.
			initContainers: [
				{
					name: 'home',
					image: ORB_IMAGE,
					securityContext: { runAsUser: 0 },
					command: [
						'sh',
						'-c',
						'[ -e /mnt/home/.orb-home ] || { cp -a /home/user/. /mnt/home/ && chown -R user:user /mnt/home && touch /mnt/home/.orb-home; }',
					],
					volumeMounts: [{ name: 'home', mountPath: '/mnt/home' }],
				},
			],
			containers: [
				{
					name: 'orb',
					image: ORB_IMAGE,
					// Bootstrap logs to a file by default; the pod log reaches kubectl and Loki.
					command: ['bash', '-lc', 'exec amp orb bootstrap --log-file /dev/stdout'],
					envFrom: [{ secretRef: { name: names.env } }],
					resources: {
						requests: { cpu: '1', memory: '4Gi' },
						limits: { cpu: '4', memory: '8Gi' },
					},
					volumeMounts: [{ name: 'home', mountPath: '/home/user' }],
				},
			],
		},
	}
}

async function spawn() {
	// Every spawn carries a fresh ORB_TOKEN, so a running orb restarts to pick it up.
	await removePod()
	const env = { ORB_TOKEN, ...(AMP_URL && { AMP_URL }) }
	const secret = { metadata: { name: names.env, labels }, type: 'Opaque', stringData: env }
	if (await request('GET', core('secrets', names.env))) await request('PUT', core('secrets', names.env), secret)
	else await request('POST', core('secrets'), secret)
	await ensure('persistentvolumeclaims', names.home, {
		metadata: { name: names.home, labels },
		spec: {
			accessModes: ['ReadWriteOnce'],
			storageClassName: 'orb-storage',
			resources: { requests: { storage: '30Gi' } },
		},
	})
	await request('POST', core('pods'), orbPod())
	// The first pull of Amp's 7 GiB image can outlast Amp's five-minute job limit; Amp waits for bootstrap anyway.
	const running = await waitFor(async () => (await request('GET', core('pods', names.pod)))?.status?.phase === 'Running', 240)
	console.log(running ? `orb ${ORB_ID} running` : `orb ${ORB_ID} still starting`)
}

async function remove() {
	await removePod()
	await request('DELETE', core('persistentvolumeclaims', names.home))
	await request('DELETE', core('secrets', names.env))
}

const operations = { spawn, pause: removePod, delete: remove }
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
