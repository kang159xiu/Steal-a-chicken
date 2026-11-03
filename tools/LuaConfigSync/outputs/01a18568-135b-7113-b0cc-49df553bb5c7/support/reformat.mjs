import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {Workbook,SpreadsheetFile} from '@oai/artifact-tool';
const support=path.dirname(fileURLToPath(import.meta.url)),out=path.dirname(support);
const data=JSON.parse(await fs.readFile(path.join(support,'reformat-input.json'),'utf8'));
const records=data.records,used=new Set(),mapping=[],previews=[];
const gameBefore=await fs.readFile(path.join(data.project,data.relative));
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const old=path.join(out,'游戏配置数值调整表.xlsx');
if(hash(await fs.readFile(old))!==data.oldWorkbookHash)throw Error('Input workbook changed');
const wb=Workbook.create();
function col(n){let s='';for(n++;n;n=Math.floor((n-1)/26))s=String.fromCharCode(65+(n-1)%26)+s;return s;}
const states=new Map();
function sheet(name,color='#58735E'){
 if(states.has(name))return states.get(name);
 const sh=wb.worksheets.add(name);sh.showGridLines=false;sh.tabColor=color;
 sh.freezePanes.freezeRows(4);sh.freezePanes.freezeColumns(1);
 const state={sh,next:3,table:0};states.set(name,state);return state;
}
function style(sh,range){sh.getRange(range).format.font={name:'Microsoft YaHei',size:11,color:'#263544'};sh.getRange(range).format.rowHeight=29;}
function mark(r,name,orig,edit){
 if(used.has(r.path))throw Error('Repeated field '+r.path);used.add(r.path);
 mapping.push({path:r.path,sheet:name,originalCell:orig,modifiedCell:edit,file:r.file,type:r.type,baseline:r.value,modified:r.modified,readOnly:r.readOnly,raw:r.raw});
}
function put(sh,addr,v,type){const cell=sh.getRange(addr);if(type==='string'||type==='expression'||type==='nil'||type==='boolean')cell.setNumberFormat('@');cell.values=[[v]];if(type==='number')cell.setNumberFormat(Number.isInteger(v)?'0':'0.###############');}
function pivot(name,title,rs,keyOf,metrics,idField=null,idLabel='配置对象'){
 if(!rs.length)return;
 const {sh}=sheet(name),state=states.get(name),start=state.next,head=start+1;
 sh.getRange('A'+start).values=[[title]];sh.getRange('A'+start).format.font={name:'Microsoft YaHei',bold:true,size:14,color:'#314F3A'};
 const groups=new Map();for(const r of rs){const key=keyOf(r);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(r);}
 const headers=[idLabel,...metrics.flatMap(m=>[m.label+'·原值',m.label+'·修改值'])];
 const end=col(headers.length-1);sh.getRange('A'+head+':'+end+head).values=[headers];
 let row=head+1;
 for(const [key,items] of groups){
  const identity=idField?items.find(r=>r.path.endsWith('.'+idField)):null;
  put(sh,'A'+row,identity?identity.value:key,identity?.type??'string');
  if(identity)mark(identity,name,'A'+row,'A'+row);
  for(let i=0;i<metrics.length;i++){
   const metric=metrics[i],r=items.find(metric.test),orig=col(1+2*i)+row,edit=col(2+2*i)+row;
   if(!r){put(sh,orig,'—','string');put(sh,edit,'—','string');continue;}
   put(sh,orig,r.value,r.type);put(sh,edit,r.modified,r.type);mark(r,name,orig,edit);
   sh.getRange(orig).format.fill='#F0F2F4';sh.getRange(edit).format.fill=r.readOnly?'#E2E6EB':'#FFF2CC';
   if(r.type==='boolean'&&!r.readOnly)sh.getRange(edit).dataValidation={rule:{type:'list',values:['true','false']}};
  }row++;
 }
 style(sh,'A'+head+':'+end+(row-1));
 sh.getRange('A'+head+':'+end+head).format.fill='#3F624C';sh.getRange('A'+head+':'+end+head).format.font={name:'Microsoft YaHei',bold:true,size:10,color:'#FFFFFF'};sh.getRange('A'+head+':'+end+head).format.rowHeight=40;
 sh.getRange('A:A').format.columnWidth=27;
 for(let i=1;i<headers.length;i++){
  const c=col(i),metric=metrics[Math.floor((i-1)/2)];
  const vals=rs.filter(metric.test);const max=Math.max(0,...vals.map(r=>String(r.value??'').length),...vals.map(r=>String(r.modified??'').length));
  sh.getRange(c+':'+c).format.columnWidth=Math.max(22,Math.min(52,max+3));
 }
 sh.tables.add('A'+head+':'+end+(row-1),true,'T'+states.size+'_'+state.table++).showBandedRows=false;
 // Reapply the input cues after adding the native filter table.
 for(const m of mapping.filter(m=>m.sheet===name&&Number(m.originalCell.match(/\d+/)[0])>head)){
  sh.getRange(m.originalCell).format.fill='#F0F2F4';sh.getRange(m.modifiedCell).format.fill=m.readOnly?'#E2E6EB':'#FFF2CC';
 }
 if(!previews.some(p=>p.name===name))previews.push({name,range:'A'+start+':'+col(Math.min(headers.length-1,8))+Math.min(row-1,head+5)});
 state.next=row+3;
}
const leaf=r=>r.path.split('.').at(-1),metric=(key,label)=>({label,test:r=>leaf(r)===key});
const take=f=>records.filter(r=>!used.has(r.path)&&f(r));
sheet('使用说明','#355878');
pivot('鸡与蛋价值','鸡售价与蛋产出',take(r=>/^GameConfig.ChickenTypes\./.test(r.path)&&['ChickenSellPrice','SellPrice','ProductionIntervalSeconds','HatchDurationSeconds'].includes(leaf(r))),r=>r.path.match(/ChickenTypes\.(Chicken\d+)/)[1],[metric('ChickenSellPrice','鸡售价'),metric('SellPrice','蛋售价'),metric('ProductionIntervalSeconds','产蛋间隔（秒）'),metric('HatchDurationSeconds','蛋成长时长（秒）')]);
pivot('家园升级消耗','各级家园升级与容量',take(r=>r.path.startsWith('GameConfig.HomeLevels')),r=>r.path.match(/HomeLevels\[(\d+)\]/)[1],[metric('UpgradeCost','升级价格'),metric('ChickenCapacity','鸡容量'),metric('EggCapacity','蛋容量')],'Level','等级');
pivot('跑步机升级消耗','各级跑步机升级与经验',take(r=>r.path.startsWith('GameConfig.TreadmillLevels')&&leaf(r)!=='TemplateRootId'),r=>r.path.match(/TreadmillLevels\[(\d+)\]/)[1],[metric('UpgradeCost','升级价格'),metric('ExperiencePerTick','每次训练经验')],'Level','等级');
const speed=take(r=>r.path.startsWith('GameConfig.PlayerSpeed.'));
pivot('玩家速度成长','速度与升级经验',speed,()=> '玩家速度',speed.map(r=>metric(leaf(r),r.label)));
pivot('重生需求与收益','各次重生需求与倍率',take(r=>r.path.startsWith('GameConfig.RebirthLevels')),r=>r.path.match(/RebirthLevels\[(\d+)\]/)[1],[metric('ExperienceRequired','所需经验'),metric('Multiplier','金币倍率')],'Count','重生次数');
pivot('商店价格与收益','踪迹购买价格与训练倍率',take(r=>r.path.includes('TrackShop.Tracks[')&&['Price','Multiplier'].includes(leaf(r))),r=>'踪迹'+r.path.match(/Tracks\[(\d+)\]/)[1],[metric('Price','购买价格'),metric('Multiplier','训练倍率')]);
pivot('商店价格与收益','永久倍率商品收益',take(r=>r.path.includes('MultiplierPurchase.')&&leaf(r)==='Multiplier'),r=>(r.path.includes('.Coin.')?'金币':'训练')+'商品'+r.path.match(/Products\[(\d+)\]/)[1],[metric('Multiplier','永久倍率')]);
pivot('商店价格与收益','内购重生对应次数',take(r=>r.path.includes('RebirthPurchase.Products[')&&leaf(r)==='Count'),r=>'重生商品'+r.path.match(/Products\[(\d+)\]/)[1],[metric('Count','购买前重生次数')]);
pivot('区域产出与概率','区域启用与生成数量',take(r=>/^GameConfig.Regions\[\d+\]\.(RegionId|Enabled|SpawnPointCount)$/.test(r.path)),r=>r.path.match(/Regions\[(\d+)\]/)[1],[metric('Enabled','区域启用'),metric('SpawnPointCount','生成数量')],'RegionId','区域编号');
for(const [kind,key,label] of [['ChickenPool','ChickenType','鸡类型'],['EggPool','EggTypeId','蛋类型']]){
 pivot('区域产出与概率',label+'池（权重按总和归一化）',take(r=>r.path.includes('.'+kind+'[')),r=>'区域'+r.path.match(/Regions\[(\d+)\]/)[1]+' / 池项'+r.path.match(/Pool\[(\d+)\]/)[1],[metric(key,label),metric('Weight','抽取权重')]);
}
pivot('区域产出与概率','新生成鸡的高倍率概率',take(r=>r.path.includes('.HighMultiplier')),()=> '新鸡独立抽取',[metric('HighMultiplierChanceDenominator','概率分母'),metric('HighMultiplierMin','倍率下限'),metric('HighMultiplierMax','倍率上限')]);
const guardians=take(r=>r.path.includes('.Guardian.'));
pivot('玩法参数','各区域守护者参数',guardians,r=>'区域'+r.path.match(/Regions\[(\d+)\]/)[1],[...new Map(guardians.map(r=>[leaf(r),r])).values()].map(r=>metric(leaf(r),r.label)));
function longTable(name,title,rs){
 if(!rs.length)return;const {sh}=sheet(name,name==='系统配置（只读）'?'#87929B':'#596F8B'),st=states.get(name),start=st.next,h=start+1;
 sh.getRange('A'+start).values=[[title]];sh.getRange('A'+start).format.font={name:'Microsoft YaHei',size:14,bold:true,color:'#31485D'};
 const values=[['用途 / 系统','配置对象','字段名称','原值','修改值','Lua类型','编辑状态','说明'],...rs.map(r=>[r.path.split('.')[1].replace(/\[.*$/,''),r.object,r.label,r.value,r.modified,r.type,r.readOnly?'只读':'可修改',r.note])];
 sh.getRange('A'+h+':H'+(h+rs.length)).values=values;style(sh,'A'+h+':H'+(h+rs.length));
 for(let i=0;i<rs.length;i++){const r=rs[i],row=h+i+1;put(sh,'D'+row,r.value,r.type);put(sh,'E'+row,r.modified,r.type);mark(r,name,'D'+row,'E'+row);sh.getRange('D'+row).format.fill='#F0F2F4';sh.getRange('E'+row).format.fill=r.readOnly?'#E2E6EB':'#FFF2CC';}
 for(const [c,w] of [['A',25],['B',27],['C',35],['D',51],['E',51],['F',13],['G',12],['H',58]])sh.getRange(c+':'+c).format.columnWidth=w;
 sh.getRange('A'+h+':H'+h).format.fill='#355878';sh.getRange('A'+h+':H'+h).format.font={name:'Microsoft YaHei',size:10,bold:true,color:'#FFFFFF'};
 sh.tables.add('A'+h+':H'+(h+rs.length),true,'L'+states.size+'_'+st.table++);
 if(!previews.some(p=>p.name===name))previews.push({name,range:'A'+start+':G'+Math.min(h+rs.length,h+5)});st.next=h+rs.length+4;
}
// Resource IDs, names, property contracts and product identifiers are kept together.
const sys=r=>r.sheet==='系统只读'||r.type==='expression'||r.type==='nil'||leaf(r)==='NeedsConfirmation';
const resource=r=>/Ids?$/.test(leaf(r))||r.type==='string'&&!/^\d+$/.test(String(r.value));
longTable('玩法参数','其他玩法参数',take(r=>!sys(r)&&!resource(r)));
longTable('ID与资源配置','模型、UI、属性名称与商品标识',take(r=>!sys(r)));
longTable('系统配置（只读）','系统、存档、顺序及引擎表达式',take(()=>true));
if(used.size!==records.length)throw Error('Missing fields');
const map=sheet('字段映射','#87929B').sh;
const mh=['代码文件相对路径','Lua字段路径','Lua类型','导出基线值','数值工作表','原值单元格','修改值单元格','编辑状态','原始Lua字面量','导出源文件SHA256'];
map.getRange('A1:J'+(mapping.length+1)).values=[mh,...mapping.map(m=>[m.file,m.path,m.type,m.baseline,m.sheet,m.originalCell,m.modifiedCell,m.readOnly?'只读':'可修改',m.raw,data.hash])];
for(let i=0;i<mapping.length;i++)put(map,'D'+(i+2),mapping[i].baseline,mapping[i].type);
style(map,'A1:J'+(mapping.length+1));map.getRange('A1:J1').format.fill='#355878';map.getRange('A1:J1').format.font={bold:true,color:'#FFFFFF'};
for(const [c,w] of [['A',39],['B',85],['C',13],['D',52],['E',25],['F',16],['G',16],['H',12],['I',52],['J',70]])map.getRange(c+':'+c).format.columnWidth=w;
map.tables.add('A1:J'+(mapping.length+1),true,'Mapping');map.freezePanes.freezeRows(1);
previews.push({name:'字段映射',range:'A1:D6'});
const intro=states.get('使用说明').sh;
const rows=[['游戏经济与配置调整表',''],['如何修改','只改黄色“修改值”列；原值相邻对照，灰色项保持原样。'],['经济分类','鸡与蛋价值、家园升级、跑步机升级、速度成长、重生、商店及区域概率。'],['资源分类','模型、UI、触发盒、图片组、商品标识和属性名称集中在“ID与资源配置”。'],['精度','大整数价格、经验及商品标识保留为文本；不要转为科学计数法或公式。'],['填写规则','数字保持数字；布尔填 true/false；字符串直接填写，不添加 Lua 引号。'],['原表内容','已保留原表全部原值和修改值；未按当前源码重新覆盖基线。'],['同步方式','改完保存后告诉我，再核对差异与源码冲突并同步；本次没有改游戏数值。'],['注意事项','不要清空单元格、改映射、增删配置行；需要空字符串时先告诉我。'],['只读说明','灰色标识为只读提示；未设置工作表密码，请按颜色和编辑状态填写。'],['范围','共 '+records.length+' 个配置字段；各字段仅有一个编辑位置，技术映射位于末尾。'],['来源基线日期',data.date],['整理日期','2026-10-30'],['源文件相对路径',data.relative],['导出基线SHA256',data.hash],['生效方式','同步后编辑器重新开局；线上仍需发布。']];
intro.getRange('A1:B'+rows.length).values=rows;style(intro,'A1:B'+rows.length);intro.getRange('A:A').format.columnWidth=22;intro.getRange('B:B').format.columnWidth=115;intro.getRange('A1:B1').format.font={name:'Microsoft YaHei',size:16,bold:true,color:'#243247'};intro.getRange('A1:B16').format.rowHeight=31;intro.getRange('B2').format.fill='#FFF2CC';intro.freezePanes.unfreeze();
previews.unshift({name:'使用说明',range:'A1:B8'});
wb.recalculate();
console.log((await wb.inspect({kind:'match',searchTerm:'#REF!|#DIV/0!|#VALUE!|#NAME\\?|#NUM!|#N/A',options:{useRegex:true,maxResults:10},maxChars:500})).ndjson);
const output=path.join(out,'游戏经济与配置调整表.xlsx');await(await SpreadsheetFile.exportXlsx(wb)).save(output);
await fs.writeFile(path.join(support,'reformat-mapping.json'),JSON.stringify({sourceWorkbook:old,sourceWorkbookHash:data.oldWorkbookHash,baselineHash:data.hash,records:mapping},null,2));
for(const p of previews){const im=await wb.render({sheetName:p.name,range:p.range,scale:1,format:'png'});await fs.writeFile(path.join(support,'new-'+p.name+'.png'),new Uint8Array(await im.arrayBuffer()));}
if(hash(await fs.readFile(old))!==data.oldWorkbookHash||!gameBefore.equals(await fs.readFile(path.join(data.project,data.relative))))throw Error('Protected input changed');
console.log(JSON.stringify({output,fields:used.size,sheets:[...states.keys()]}));
