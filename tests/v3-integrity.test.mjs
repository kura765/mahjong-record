// Run: node --test tests/v3-integrity.test.mjs
// Pure-function regression tests. No Supabase project or external packages needed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';

const root=path.resolve(import.meta.dirname,'..');
const html=readFileSync(path.join(root,'v3/cloud.html'),'utf8');
const trial=readFileSync(path.join(root,'v3/play.html'),'utf8');
const production=readFileSync(path.join(root,'index.html'),'utf8');
const sql=readFileSync(path.join(root,'supabase/v3_isolated_schema.sql'),'utf8');
const script=html.split('<script type="module">')[1]?.split('</script>')[0];
assert.ok(script,'cloud module missing');

function extract(start,end){
 const a=script.indexOf(start),b=script.indexOf(end,a+start.length);
 assert.ok(a>=0&&b>a,`function boundaries missing: ${start}`);
 return script.slice(a,b);
}
const stableCode=extract('function stableJson(', 'function stopAutoSync(');
const candidateCode=extract('function originalMatchId(', '$("scanUpdates").onclick');
const pullCode=extract('function comparePullData(', 'function invalidatePull(');
const guidedCode=extract('function planGuidedSync(', '$("guideSync").onclick');
const pendingCode=extract('const matchStateLabel=', 'function countLocalChanges(');
const validateCode=extract('function checkedBackup(', 'function prepareImport(');
const restoreCode=extract('function reconstructBackup(', '$("export").onclick');
const mocks={
 window:{addEventListener(){}},
 Blob: class Blob { constructor(items){this.size=Buffer.byteLength(items.join(''));} }
};
const evaluated=vm.runInNewContext(
 stableCode+candidateCode+validateCode+restoreCode+pullCode+pendingCode+guidedCode+
 '\n({stableJson,buildUpdateCandidates,checkedBackup,reconstructBackup,comparePullData,planGuidedSync})',
 mocks,
 {timeout:1000}
);
const {stableJson,buildUpdateCandidates,checkedBackup,reconstructBackup,comparePullData,planGuidedSync}=evaluated;
const reg=['a','b','c','d'].map(id=>({id,name:id.toUpperCase(),deleted:false}));
const freshMatch=(id,round=0)=>({
 id,names:['A','B','C','D'],playerIds:['a','b','c','d'],
 points:[25000,25000,25000,25000],hands:Array.from({length:round},(_,i)=>({round:i}))
});
const meta={players:['A','B','C','D'],playerRegistry:reg,rules:null,ruleFormats:[],selectedRuleFormat:null,excludedStatsMatches:{}};
function fixture({completed=[],suspended=[],active=null}={}){
 return {...structuredClone(meta),matches:completed,suspendedMatches:suspended,active};
}
function record(kind,id,round=0){
 return {key:kind+':'+id,payload:{kind,match:freshMatch(id,round)}};
}
function snapshot(item,version=1){
 return {match_key:item.key,payload:item.payload,version};
}
function checkpoint(item,version=1){
 return {schema:1,roomId:'room1',meta:structuredClone(meta),items:{[item.key]:{version,payload:item.payload}}};
}
function checked(items){
 return {meta:structuredClone(meta),items};
}
function rejects(f,regexp){
 assert.throws(f,e=>regexp.test(String(e.message||e)));
}
test('Whole cloud module parses as JavaScript (without its ESM import)',()=>{
 const body=script.replace(/^import\s+\{[^}]+\}\s+from\s+["'][^"']+["'];\s*/m,'');
 assert.doesNotThrow(()=>new vm.Script(body));
});
test('Trial app parses and uses a separate storage key',()=>{
 const trialScript=trial.match(/<script>([\s\S]*)<\/script><\/body>/)?.[1];
 assert.ok(trialScript);
 assert.doesNotThrow(()=>new vm.Script(trialScript));
 assert.match(trial,/const KEY='mahjongV3Trial'/);
 assert.match(production,/const KEY='mahjongPrototypeV1'/);
 assert.doesNotMatch(trial,/const KEY='mahjongPrototypeV1'/);
});
test('Trial embeds cloud controls with a safe refresh after a cloud pull',()=>{
 assert.match(trial,/data-page="sync"/);
 assert.match(trial,/id="cloudFrame"/);
 assert.match(trial,/cloud\.html\?embedded=1/);
 assert.match(trial,/event\.key==='mahjongV3Trial'/);
 assert.match(trial,/window\.location\.reload\(\)/);
 assert.match(trial,/mahjong-v3-stop-auto/);
 assert.match(html,/event\.origin!==location\.origin/);
 assert.match(html,/stopAutoSync\("入力画面に戻ったため/);
});
test('Read-only sync overview is exposed without creating a new write path',()=>{
 assert.match(html,/id="checkSyncOverview"/);
 assert.match(html,/id="syncOverviewTitle"/);
 assert.match(script,/function countLocalChanges\(/);
 assert.match(script,/setOverview\("ok","閲覧専用"/);
 assert.match(script,/comparePullData\(local,checkpoint,resultSettings\.data\?\.payload/);
 assert.match(script,/button\.disabled=true/);
});
test('Pending match descriptions show readable names, states and changed hands',()=>{
 const helpers=extract('const matchStateLabel=', 'function countLocalChanges(');
 const {describeChange,pendingChangeDetails}=vm.runInNewContext(
  stableCode+helpers+'\n({describeChange,pendingChangeDetails})',mocks,{timeout:1000});
 const a=record('active','m1',1),b=record('completed','m1',2),fresh=record('suspended','m2',1);
 b.payload.match.title='20261126_01';
 fresh.payload.match.title='20261126_02';
 const changes=pendingChangeDetails(checked([b,fresh]),checkpoint(a));
 assert.equal(changes.length,2);
 assert.equal(changes[0].title,'20261126_01');
 assert.equal(changes[0].kind,'状態変更');
 assert.match(changes[0].description,/進行中 → 完了/);
 assert.match(changes[0].description,/\+1局/);
 assert.equal(changes[1].kind,'新規追加');
 assert.match(changes[1].description,/中断/);
 assert.equal(describeChange(a,{payload:a.payload}).kind,'内容更新');
});
test('Upload candidates display readable match names instead of raw ID keys',()=>{
 assert.match(html,/id="syncChangeList"/);
 assert.match(html,/id="updateTargetDetails"/);
 assert.match(script,/new Option\(describeChange\(x\.item/);
 assert.match(script,/showUpdateTargetDetails\(\)/);
 assert.match(script,/document\.createTextNode\(row\.description\)/);
});
test('Guided sync previews outgoing, incoming and clean cases without writing',()=>{
 const base=record('active','m1',1),local=record('active','m1',2),remote=record('active','m1',3);
 const outgoing=planGuidedSync(checked([local]),checkpoint(base),meta,[snapshot(base)],'room1');
 assert.equal(outgoing.status,'send');
 assert.equal(outgoing.outgoing.length,1);
 assert.equal(outgoing.incoming,0);
 const incoming=planGuidedSync(checked([base]),checkpoint(base),meta,[snapshot(remote,2)],'room1');
 assert.equal(incoming.status,'receive');
 assert.equal(incoming.incoming,1);
 assert.equal(incoming.outgoing.length,0);
 const clean=planGuidedSync(checked([base]),checkpoint(base),meta,[snapshot(base)],'room1');
 assert.equal(clean.status,'clean');
 assert.equal(clean.incoming,0);
 assert.equal(clean.outgoing.length,0);
});
test('Guided sync rejects a conflicting concurrent change',()=>{
 const base=record('active','m1',1),local=record('active','m1',2),server=record('active','m1',3);
 rejects(()=>planGuidedSync(checked([local]),checkpoint(base),meta,[snapshot(server,2)],'room1'),/両方で変更/);
});
test('Guided sync never offers uploads before remote changes are retrieved',()=>{
 const base=record('active','m1',1),local=record('completed','m2',1),server=record('active','m1',2);
 const result=planGuidedSync(checked([base,local]),checkpoint(base),meta,[snapshot(server,2)],'room1');
 assert.equal(result.status,'receive');
 assert.equal(result.incoming,1);
 assert.equal(result.outgoing.length,1);
 assert.match(script,/id\=\"guideSync\"|\$\("guideSync"\)/);
});
test('Cloud notice does not overlap sync controls in embedded mobile view',()=>{
 assert.doesNotMatch(html,/#message\{[^}]*position:sticky/);
 assert.match(html,/#message\{position:static/);
 assert.match(html,/#message\.error\{/);
 assert.match(html,/id="guideSync"/);
});
test('Complete backup validates without modifying source',()=>{
 const data=fixture({completed:[freshMatch('m1')]});
 const saved=JSON.stringify(data),x=checkedBackup(data);
 assert.equal(x.items.length,1);
 assert.equal(x.items[0].key,'completed:m1');
 assert.deepEqual(JSON.parse(JSON.stringify(x.meta.playerRegistry)),reg);
 assert.equal(JSON.stringify(data),saved);
});
test('Duplicate original ID across states is rejected',()=>{
 rejects(()=>checkedBackup(fixture({completed:[freshMatch('m1')],suspended:[freshMatch('m1')]})),/重複/);
});
test('Missing player reference is rejected',()=>{
 const m=freshMatch('m1');m.playerIds[0]='missing';
 rejects(()=>checkedBackup(fixture({completed:[m]})),/不整合/);
});
test('Stable comparison ignores object property order',()=>{
 assert.equal(stableJson({z:2,a:{y:1,x:2}}),stableJson({a:{x:2,y:1},z:2}));
});
test('No changes creates no upload candidates',()=>{
 const x=record('active','m1');
 assert.equal(buildUpdateCandidates(checked([x]),checkpoint(x),new Map([[x.key,snapshot(x)]]),'room1').length,0);
});
test('Local match edit creates versioned update',()=>{
 const original=record('active','m1'),newer=record('active','m1',1);
 const candidates=buildUpdateCandidates(checked([newer]),checkpoint(original,3),new Map([[original.key,snapshot(original,3)]]),'room1');
 assert.equal(candidates[0].kind,'更新'); assert.equal(candidates[0].expected,3);
});
test('Local active-to-completed move creates lifecycle transition',()=>{
 const original=record('active','m1'),finished=record('completed','m1',2);
 const candidate=buildUpdateCandidates(checked([finished]),checkpoint(original,2),new Map([[original.key,snapshot(original,2)]]),'room1')[0];
 assert.equal(candidate.kind,'状態変更');assert.equal(candidate.oldKey,original.key);
});
test('Completed-to-active rollback is blocked',()=>{
 const done=record('completed','m1'),active=record('active','m1');
 rejects(()=>buildUpdateCandidates(checked([active]),checkpoint(done),new Map([[done.key,snapshot(done)]]),'room1'),/未対応/);
});
test('Cloud revision conflict blocks an upload',()=>{
 const original=record('active','m1'),changed=record('active','m1',1);
 rejects(()=>buildUpdateCandidates(checked([changed]),checkpoint(original),new Map([[original.key,snapshot(original,2)]]),'room1'),/変更/);
});
test('Cloud pull accepts a remote-only edit',()=>{
 const a=record('active','m1'),b=record('active','m1',1);
 const result=comparePullData(checked([a]),checkpoint(a),meta,[snapshot(b,2)]);
 assert.equal(result.pulled,1);assert.equal(result.merged.active.hands.length,1);
});
test('Cloud pull preserves a local-only edit',()=>{
 const a=record('active','m1'),local=record('active','m1',2);
 const result=comparePullData(checked([local]),checkpoint(a),meta,[snapshot(a)]);
 assert.equal(result.pulled,0);assert.equal(result.preserved,1);
 assert.equal(result.merged.active.hands.length,2);
});
test('Cloud pull adds an unrelated remote match',()=>{
 const a=record('active','m1'),b=record('completed','m2');
 const result=comparePullData(checked([a]),checkpoint(a),meta,[snapshot(a),snapshot(b)]);
 assert.equal(result.pulled,1);assert.equal(result.merged.matches.length,1);
});
test('Cloud pull accepts remote active-to-completed transition',()=>{
 const a=record('active','m1'),b=record('completed','m1',1);
 const result=comparePullData(checked([a]),checkpoint(a),meta,[snapshot(b,2)]);
 assert.equal(result.merged.active,null);assert.equal(result.merged.matches.length,1);
});
test('Cloud pull refuses concurrent local and remote edits',()=>{
 const a=record('active','m1'),b=record('active','m1',1),c=record('active','m1',2);
 rejects(()=>comparePullData(checked([b]),checkpoint(a),meta,[snapshot(c,2)]),/両方/);
});
test('Cloud-wins recovery is opt-in and preserves unrelated local edits',()=>{
 const base=record('suspended','m1',1),server=record('active','m1',2),local=record('completed','m1',2);
 const unrelated=record('completed','m2',3);
 const result=comparePullData(checked([local,unrelated]),checkpoint(base),meta,[snapshot(server,2)]);
 assert.equal(result.pulled,1);
 assert.equal(result.conflictsResolved,1);
 assert.equal(result.merged.active.hands.length,2);
 assert.equal(result.merged.matches.length,1);
 assert.equal(result.merged.matches[0].id,'m2');
 assert.ok(result.rebased);
 assert.ok(result.checkpoint.items['active:m1']);
});
test('Cloud-wins recovery still rejects metadata mismatch',()=>{
 const base=record('active','m1'),local=record('active','m1',1),server=record('active','m1',2);
 rejects(()=>comparePullData(checked([local]),checkpoint(base),{...meta,players:['wrong']},[snapshot(server,2)],true),/設定/);
});
test('Cloud-wins recovery refuses a new untracked duplicate',()=>{
 const original=record('active','m1'),local=record('completed','m2',1),remote=record('suspended','m2',2);
 rejects(()=>comparePullData(checked([original,local]),checkpoint(original),meta,[snapshot(original),snapshot(remote)],true),/未追跡/);
});
test('Identical local and cloud records can rebase stale checkpoint',()=>{
 const a=record('suspended','m1',1),b=record('active','m1',2);
 const result=comparePullData(checked([b]),checkpoint(a),meta,[snapshot(b,2)]);
 assert.equal(result.pulled,0);
 assert.equal(result.conflictsResolved,0);
 assert.equal(result.preserved,0);
 assert.equal(result.rebased,true);
 assert.ok(result.checkpoint.items['active:m1']);
});
test('Cloud pull refuses conflicting metadata',()=>{
 const a=record('active','m1');
 rejects(()=>comparePullData(checked([a]),checkpoint(a),{...meta,players:['wrong']},[snapshot(a)]),/設定/);
});
test('Reconstruction refuses duplicate IDs across states',()=>{
 const a=record('active','m1'),b=record('completed','m1');
 rejects(()=>reconstructBackup(meta,[snapshot(a),snapshot(b)]),/同一/);
});
test('SQL integrity: single transaction, balanced functions, RLS and versioning',()=>{
 const functions=(sql.match(/^create or replace function/gm)||[]).length;
 const delimiters=(sql.match(/\$\$/g)||[]).length;
 assert.equal(delimiters,functions*2);
 assert.equal((sql.match(/^commit;$/gm)||[]).length,1);
 for(const table of ['mahjong_v3_rooms','mahjong_v3_room_members','mahjong_v3_room_matches','mahjong_v3_room_backup_meta','mahjong_v3_room_match_history','mahjong_v3_room_invites'])
  assert.ok(sql.includes('alter table public.'+table+' enable row level security;'));
 assert.match(sql,/mahjong_v3_transition_match/);
 assert.match(sql,/Version conflict/);
 assert.match(sql,/pg_advisory_xact_lock/);
});
