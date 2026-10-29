#!/usr/bin/env node
// Deletes the disks, env Secret and halted VMs of orbs paused longer than
// RECLAIM_DAYS, so archived threads do not keep their disks forever. A thread that
// comes back gets a fresh orb: Amp clones the repository and runs setup again.
// Also deletes the home PVCs orbs had before the state disk, which nothing mounts.
import { readFileSync } from 'node:fs'

const serviceAccount = '/var/run/secrets/kubernetes.io/serviceaccount'
const namespace = readFileSync(`${serviceAccount}/namespace`, 'utf8').trim()
const token = readFileSync(`${serviceAccount}/token`, 'utf8').trim()
const api = `https://${process.env.KUBERNETES_SERVICE_HOST}:${process.env.KUBERNETES_SERVICE_PORT}`
const days = Number(process.env.RECLAIM_DAYS)
if (!(days > 0)) throw new Error(`unexpected RECLAIM_DAYS: ${process.env.RECLAIM_DAYS}`)

// Set by dispatch.mjs: when the orb paused, cleared when it spawns again.
const pausedAt = 'amp.ampcode.com/paused-at'
const orbId = 'amp.ampcode.com/orb-id'

async function request(method, path, body, contentType = 'application/json') {
	const response = await fetch(`${api}${path}`, {
		method,
		headers: { authorization: `Bearer ${token}`, 'content-type': contentType },
		body: body && JSON.stringify(body),
	})
	if (response.status === 404 && method === 'DELETE') return null
	if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`)
	return response.json()
}

const core = (kind, name = '') => `/api/v1/namespaces/${namespace}/${kind}${name && `/${name}`}`
const kubevirt = (kind, name = '') => `/apis/kubevirt.io/v1/namespaces/${namespace}/${kind}${name && `/${name}`}`
const orbs = `?labelSelector=${encodeURIComponent('app.kubernetes.io/name=amp-orb')}`
const log = (fields) => console.log(JSON.stringify({ msg: 'orb reclaim', ...fields }))

const running = new Set((await request('GET', kubevirt('virtualmachineinstances') + orbs)).items.map((vmi) => vmi.metadata.labels[orbId]))
const claims = (await request('GET', core('persistentvolumeclaims') + orbs)).items
const vms = (await request('GET', kubevirt('virtualmachines') + orbs)).items
const now = Date.now()

for (const claim of claims) {
	const { name, labels, annotations = {} } = claim.metadata
	const id = labels[orbId]
	if (running.has(id)) continue
	if (name === `${id}-home`) {
		await request('DELETE', core('persistentvolumeclaims', name))
		log({ orb: id, result: 'deleted home disk' })
		continue
	}
	if (name !== `${id}-state`) continue
	// Orbs paused before dispatch.mjs recorded it, or stopped without a pause, start counting now.
	if (!annotations[pausedAt]) {
		const patch = { metadata: { annotations: { [pausedAt]: new Date(now).toISOString() } } }
		await request('PATCH', core('persistentvolumeclaims', name), patch, 'application/merge-patch+json')
		continue
	}
	const pausedDays = (now - Date.parse(annotations[pausedAt])) / 86_400_000
	if (!(pausedDays > days)) continue
	for (const vm of vms.filter((vm) => vm.metadata.labels[orbId] === id)) {
		await request('DELETE', kubevirt('virtualmachines', vm.metadata.name))
	}
	await request('DELETE', core('persistentvolumeclaims', `${id}-state`))
	await request('DELETE', core('persistentvolumeclaims', `${id}-swap`))
	await request('DELETE', core('secrets', `${id}-env`))
	log({ orb: id, result: 'reclaimed', pausedDays: Math.floor(pausedDays) })
}
