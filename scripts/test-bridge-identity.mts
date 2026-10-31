import assert from 'node:assert/strict';
import { distinctBridges, distinctBridgesV3 } from '../convex/convex/bridgeIdentity.ts';
const row=(bridgeId,updatedAt,fields={})=>({bridgeId,updatedAt,machineName:'MacBook Air',...fields});
assert.deepEqual(distinctBridges([row('old',1,{e2ePub:'key'}),row('new',2,{e2ePub:'key'})]).map(x=>x.bridgeId),['new']);
assert.equal(distinctBridges([row('one',1),row('two',2)]).length,2);
assert.deepEqual(distinctBridges([row('one',1,{machineId:'m',e2ePub:'k1'}),row('two',3,{machineId:'m',e2ePub:'k2'}),row('three',2,{e2ePub:'k1'})]).map(x=>x.bridgeId),['two']);
assert.equal(distinctBridges([row('one',1,{relayId:'r',relayURL:'wss://a'}),row('two',2,{relayId:'r',relayURL:'wss://b'})]).length,2);
assert.deepEqual(distinctBridges([row('a',1,{e2ePub:'k',relayId:'r',relayURL:'wss://a'}),row('b',3,{e2ePub:'k'}),row('c',2,{relayId:'r',relayURL:'wss://a'})]).map(x=>x.bridgeId),['b']);
console.log('PASS: duplicate IDs, separate same-name Macs, key rotation, relay scope, transitive aliases');

// v3（spec/PROTOCOL-v3.md §15.2）: bridgePub と relayId の両方が同じ行だけをまとめる。
const v3=(bridgeId,updatedAt,bridgePub,relayId,machineId)=>({bridgeId,updatedAt,bridgePub,relayId,machineId,machineName:'MacBook Air'});
assert.equal(distinctBridgesV3([v3('a',1,'k','r1'),v3('b',2,'k','r2')]).length,2);
assert.equal(distinctBridgesV3([v3('a',1,'k1','r'),v3('b',2,'k2','r')]).length,2);
assert.equal(distinctBridgesV3([v3('a',1,'k1','r1','m'),v3('b',2,'k2','r2','m')]).length,2);
assert.deepEqual(distinctBridgesV3([v3('old',1,'k','r'),v3('new',2,'k','r')]).map(x=>x.bridgeId),['new']);
assert.equal(distinctBridgesV3([v3('a',1,'k','r1'),v3('b',2,'k','r2'),v3('c',3,'k3','r2')]).length,3);
console.log('PASS (v3): only bridgePub+relayId merges; key-only, relay-only, machineId-only and transitive rows stay separate');
