import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {Workbook, SpreadsheetFile} from '@oai/artifact-tool';
const require=createRequire(import.meta.url);
const lua=require('./luaparse.cjs');
const support=path.dirname(fileURLToPath(import.meta.url)), out=path.dirname(support);
const project=path.resolve(out,'../../../..');
const relative='src/Common/Config/GameConfig.lua', sourceFile=path.join(project,relative);
const bytes=await fs.readFile(sourceFile), source=bytes.toString('utf8');
const hash=crypto.createHash('sha256').update(bytes).digest('hex');
const ast=lua.parse(source,{luaVersion:'5.1',ranges:true,locations:true,encodingMode:'none'});
const root=ast.body.find(n=>n.type==='LocalStatement'&&n.variables.some(v=>v.name==='GameConfig'))?.init[0];
if(root?.type!=='TableConstructorExpression'||ast.body.at(-1)?.type!=='ReturnStatement') throw Error('Unexpected configuration structure');
const names={
 Enabled:'启用',DisplayName:'显示名称',TemplateRootId:'模型模板根元件 ID',RequiredPurpose:'模型作用属性值',ChickenIconIndex:'鸡图标序号',ChickenSellPrice:'鸡基础售价',EggTypeId:'蛋类型编号',IconIndex:'图标序号',ProductionIntervalSeconds:'产蛋间隔（秒）',HatchDurationSeconds:'蛋成长时长（秒）',SellPrice:'蛋基础售价',RegionId:'区域编号',RegionRootId:'区域根元件 ID',SpawnPointCount:'每区生成数量',ChickenType:'鸡类型编号',Weight:'抽取权重',TrackDelaySeconds:'开始追踪延迟（秒）',InitialSpeed:'初始速度',Acceleration:'加速度',MaxSpeed:'最大速度',KeepDistance:'保持距离',KnockbackHorizontalForce:'击飞水平力度',KnockbackUpForce:'击飞向上力度',NeedsConfirmation:'仍待策划确认',Level:'等级',ChickenCapacity:'鸡容量',EggCapacity:'蛋容量',UpgradeCost:'升级价格',ExperiencePerTick:'每次训练基础经验',ExperienceRequired:'所需经验',Multiplier:'倍率',Count:'重生次数',Price:'价格',Name:'名称',GoodsId:'商品编号',ItemId:'商品标识',DefaultLevel:'初始等级',MaxLevel:'最大等级',ExperienceTickSeconds:'经验结算间隔（秒）',BaseWalkSpeed:'基础行走速度',WalkSpeedPerLevel:'每级增加速度',FirstUpgradeExperience:'首次升级经验',ExperienceGrowthPercent:'升级经验增长百分数',MaxCount:'最大重生次数',MaxPlayers:'最大玩家数',MidJoinTeleportDelaySeconds:'中途加入传送延迟（秒）',RootElementIds:'家园根元件 ID',PurposeProperty:'作用属性名',HomePurpose:'家园作用值',OwnerNameProperty:'归属玩家属性名',ReturnPointPurpose:'家园返回点作用值',NamePurpose:'名称作用值',PlacementSlotProperty:'放置位属性名',SecondaryBuildingProperty:'二级建筑属性名',SecondaryBuildingValue:'二级建筑属性值',SecondaryBuildingMinLevel:'二级建筑最低等级',DefaultChickenCapacity:'默认鸡容量',DefaultEggCapacity:'默认蛋容量',EggPositionPurpose:'产蛋位置作用值',ChickenCountPurpose:'鸡数量作用值',EggCountPurpose:'蛋数量作用值',InitialUnlockedSlots:'初始解锁放置位数量',UnlockedSlotColor:'已解锁颜色',LockedSlotColor:'未解锁颜色',SlotColorArea:'颜色区域',InteractionPurpose:'交互作用值',LevelPurpose:'等级展示作用值',MaxDistance:'交互距离上限',TrainingPurpose:'训练触发盒作用值',PositionPurpose:'跑步机作用值',ExperienceDisplayPurpose:'经验展示作用值',HighMultiplierChanceDenominator:'高倍率概率分母',HighMultiplierMin:'高倍率下限',HighMultiplierMax:'高倍率上限',InteractionEnabled:'拾取与携带启用',RegionSpawnIntervalSeconds:'区域生成间隔（秒）',EggBreakSeconds:'敲蛋时长（秒）',HatchGrowthSeconds:'孵化长大时长（秒）',HatchInitialScale:'孵化初始缩放',GuardianManualMoveSeconds:'守护者手动移动时长（秒）',ManualDropReturnSeconds:'掉落到期时长（秒）',HoldSeconds:'按住拾取时长（秒）',ProgressTickSeconds:'进度更新间隔（秒）',DistanceCheckSeconds:'距离检查间隔（秒）',MaxHorizontalDistance:'拾取三维距离上限',CarryHeight:'携带高度',BindDelayFrames:'绑定等待帧数',VerifyDelayFrames:'验证等待帧数',RegionProperty:'区域编号属性名',SpawnPointPurpose:'鸡生成点作用值',GuardianPurpose:'守护者生成点作用值',GuardianTriggerPurpose:'守护者追踪盒作用值',CharacterSocket:'角色附加插槽',SocketMode:'附加模式',IntervalSeconds:'刷新间隔（秒）',CountdownSeconds:'刷新倒计时（秒）',SignalName:'信号名称',ExecuteResetAt:'清理时机',SpawnNewChickensAt:'生成时机',SignalAudience:'信号接收范围',RestartIntervalAt:'计时间隔起点',InitialScaleUnits:'初始缩放单位',MinFinalScaleUnits:'最终缩放下限单位',MaxFinalScaleUnits:'最终缩放上限单位',ValuePurpose:'价值作用值',MultiplierPurpose:'倍率作用值',TextRefreshSeconds:'文本刷新间隔（秒）',ProgressRefreshSeconds:'列表进度刷新间隔（秒）',DisplayHeight:'展示高度',QuantityPrefix:'数量前缀',ShowOnlyInHomeArea:'仅家园内显示',ReplicateDisplayToAllPlayers:'向所有玩家同步展示',ChickenDisplayMode:'鸡展示模式',EggDisplayMode:'蛋展示模式',Chickens:'鸡库存容量',Eggs:'蛋库存容量',ChickenPropertyName:'鸡图片组属性名',EggPropertyName:'蛋图片组属性名',EggValuePurpose:'蛋价值作用值',CountdownPurpose:'倒计时作用值',ImagePropertyName:'图片组属性名',VisibleSeconds:'显示时长（秒）',HideSeconds:'隐藏间隔（秒）',AnimationIndex:'动画序号',X:'横坐标 X',Y:'纵坐标 Y',FeedbackIntervalSeconds:'反馈间隔（秒）',FeedbackAnimationIndex:'反馈动画序号',FeedbackAnimationSeconds:'反馈动画时长（秒）',FeedbackMinX:'反馈横坐标下限',FeedbackMaxX:'反馈横坐标上限',FeedbackMinY:'反馈纵坐标下限',FeedbackMaxY:'反馈纵坐标上限',TestMoneyEnabled:'测试金币按钮启用',TestMoneyAmount:'测试金币数量',HomeTriggerBoxId:'家园触发盒 ID',StolenTriggerBoxId:'偷取区触发盒 ID',GuardianPlayerAnchorSourceId:'守护者追踪锚点模板 ID',PickupIndicatorSourceId:'拾取指示器模板 ID',ServerReadyDelaySeconds:'服务端启动等待（秒）',ClientSnapshotRequestDelaySeconds:'客户端快照请求等待（秒）',EngineOperationDelayFrames:'引擎操作等待帧数',SaveIntervalSeconds:'保存间隔（秒）',ProductionEnabled:'正式存档启用',ProbeEnabled:'存档探针启用',ProbeMode:'探针模式',ProductionPrefix:'正式存档前缀',ProbePrefix:'探针存档前缀',ProbeSegmentCount:'探针分段数',ProbePaddingLength:'探针填充长度',SegmentCount:'存档分段数',ValueLimit:'单值长度限制',SegmentPayload:'分段有效负载',SourceElementId:'引导线起点 ID',TargetElementId:'引导线终点 ID',EffectType:'特效类型',UpdateSeconds:'更新间隔（秒）'
};
const groups={Home:'家园基础',HomeUpgrade:'家园升级',HomeLevels:'家园等级',Treadmill:'跑步机',TreadmillLevels:'跑步机等级',PlayerSpeed:'速度成长',Rebirth:'重生',RebirthLevels:'重生等级',RebirthPurchase:'重生购买',TrackShop:'踪迹商店',MultiplierPurchase:'永久倍率购买',Theft:'拾取与孵化',Refresh:'刷新',EggGrowth:'蛋成长',EggCollection:'收蛋',EggCollectionList:'收蛋列表',Hotbar:'快捷栏',SellShop:'出售商店',Placement:'放置与召回',ChickenObtained:'获得鸡提示',Prompt:'通用提示',ChickenDisplay:'鸡模型展示',ImageGroups:'图片组',Zone:'区域边界',InventoryCapacity:'库存容量',Runtime:'启动时序',Persistence:'存档设置',GuideLineTest:'引导线测试',ChickenTypeOrder:'鸡展示顺序',EggTypeOrder:'蛋展示顺序'};
const sheets=['鸡基础','蛋基础','区域设置','区域鸡池','区域蛋池','守护者','家园','跑步机与成长','重生与商店','拾取与刷新','UI与资源','系统只读'];
const records=[];
function sheetOf(parts){
 const top=parts[0];
 if(top==='ChickenTypes')return parts.includes('Egg')?'蛋基础':'鸡基础';
 if(top==='Regions')return parts.includes('Guardian')?'守护者':parts.includes('ChickenPool')?'区域鸡池':parts.includes('EggPool')?'区域蛋池':'区域设置';
 if(['Runtime','Persistence','GuideLineTest','ChickenTypeOrder','EggTypeOrder'].includes(top))return '系统只读';
 if(['Home','HomeUpgrade','HomeLevels','InventoryCapacity','Zone'].includes(top))return '家园';
 if(['Treadmill','TreadmillLevels','PlayerSpeed'].includes(top))return '跑步机与成长';
 if(['Rebirth','RebirthLevels','RebirthPurchase','TrackShop','MultiplierPurchase'].includes(top))return '重生与商店';
 if(['Theft','Refresh','EggGrowth'].includes(top))return '拾取与刷新';
 return 'UI与资源';
}
function objectOf(parts){
 if(parts[0]==='ChickenTypes')return parts[1]+(parts.includes('Egg')?' / '+parts[1].replace('Chicken','Egg'):'');
 if(parts[0]==='Regions')return '区域'+parts[1]+(parts.includes('ChickenPool')?' / 鸡池项'+parts[3]:parts.includes('EggPool')?' / 蛋池项'+parts[3]:'');
 return (groups[parts[0]]??parts[0])+(typeof parts[1]==='number'?' '+parts[1]:'')+(typeof parts[1]==='string'?' / '+({Coin:'金币',Training:'训练'}[parts[1]]??parts[1]):'')+(parts.includes('Products')?' / 商品'+parts.at(-2):parts.includes('Tracks')?' / 踪迹'+parts.at(-2):'');
}
function walk(table,parts){
 let index=0;const keys=new Set();
 for(const field of table.fields){
  let key;
  if(field.type==='TableKeyString')key=field.key.name;
  else if(field.type==='TableValue')key=++index;
  else if(field.type==='TableKey'&&['StringLiteral','NumericLiteral'].includes(field.key.type))key=field.key.type==='NumericLiteral'?field.key.value:JSON.parse(field.key.raw);
  else throw Error('Unsupported key');
  if(keys.has(key))throw Error('Duplicate key '+parts.join('.')+':'+key);keys.add(key);
  const p=[...parts,key], node=field.value;
  if(node.type==='TableConstructorExpression'){walk(node,p);continue;}
  const raw=source.slice(...node.range);
  let type,value;
  if(node.type==='StringLiteral'){type='string';if(!/^"[^"\\]*"$/.test(raw))throw Error('Unexpected escaped string '+raw);value=raw.slice(1,-1);}
  else if(node.type==='NumericLiteral'||(node.type==='UnaryExpression'&&node.operator==='-'&&node.argument.type==='NumericLiteral')){type='number';value=Number(raw);if(!Number.isFinite(value)||!Number.isSafeInteger(value)&&Number.isInteger(value))throw Error('Numeric precision '+raw);}
  else if(node.type==='BooleanLiteral'){type='boolean';value=node.value?'true':'false';}
  else {type=node.type==='NilLiteral'?'nil':'expression';value=raw;}
  const fieldPath='GameConfig'+p.map(x=>typeof x==='number'?'['+x+']':'.'+x).join('');
  const sheet=sheetOf(p), readOnly=sheet==='系统只读'||['nil','expression'].includes(type)||['Level','RegionId','Count','NeedsConfirmation'].includes(key);
  let note=type==='string'&&/^\d+$/.test(value)?'文本保存；完整整数，勿使用科学计数法。':type==='boolean'?'填写 true 或 false。':type==='number'?'保持 Lua 数字类型。':type==='expression'?'引擎表达式，仅供核对。':type==='nil'?'无此项；不新增配置。':'';
  if(key==='Weight')note='相对权重，按总权重归一化；不是直接百分比。';
  if(['Level','RegionId','Count'].includes(key))note='结构编号；本轮仅调整数值，不改编号。';
  if(sheet==='系统只读')note='系统、存档或顺序配置；本轮仅供核对。';
  if(key==='NeedsConfirmation')note='策划确认标识；本轮仅供核对。';
  records.push({sheet,object:objectOf(p),label:names[key]??(String(key).endsWith('Id')?'控件/资源 ID（'+key+'）':String(key)),value,type,readOnly,note,path:fieldPath,file:relative,raw,start:node.range[0],end:node.range[1]});
 }
}
walk(root,[]);
if(new Set(records.map(x=>x.path)).size!==records.length)throw Error('Duplicate paths');
const wb=Workbook.create();
const intro=wb.worksheets.add('使用说明');intro.showGridLines=false;
const editable=records.filter(x=>!x.readOnly).length;
const instructions=[['配置数值调整表',''],['项目','Steal a chicken'],['导出日期','2026-10-30'],['使用方式','只改各分类表 C 列“修改值”的黄色单元格，保存后告诉我，再由我同步。'],['原值','D 列保留导出时原值，C 列已预填相同值；不修改即表示保持原值。'],['只读项','灰色修改值、字段路径、类型、文件路径和结构编号请保持原样。'],['精度','价格、经验及商品标识按文本保留；不要转为科学计数法或 Excel 公式。'],['类型','number 填数字；boolean 填 true/false；string 直接填内容，不添加 Lua 引号。'],['空值','不要清空单元格；需要空字符串时先告诉我。nil 和引擎枚举只读。'],['分类','鸡蛋、区域鸡池、区域蛋池、守护者、家园、成长、重生商店、拾取刷新及资源。'],['同步','本表尚未写回 Lua；改完通知我，同步前会核对类型、差异与源码冲突。'],['限制','部分数值有业务校验，不能只因 Excel 可填写就认定游戏支持。'],['生效','同步后编辑器重新开局；线上数值仍需发布。'],['来源','src/Common/Config/GameConfig.lua；从当前源码导出，不采用旧填写表。'],['字段数量',`${records.length} 项；黄色可编辑 ${editable} 项，灰色只读 ${records.length-editable} 项。`],['源文件 SHA256',hash]];
intro.getRange('A1:B'+instructions.length).values=instructions;
intro.getRange('A1:B'+instructions.length).format.font={name:'Microsoft YaHei',size:11,color:'#243247'};
intro.getRange('A:A').format.columnWidth=22;intro.getRange('B:B').format.columnWidth=110;
intro.getRange('A1:B1').format.font={bold:true,size:16,color:'#243247'};
intro.getRange('A2:A16').format.font.bold=true;
intro.getRange('A1:B16').format.rowHeight=30;intro.getRange('B4:B14').format.wrapText=true;
intro.getRange('B4').format.fill='#FFF2CC';intro.tabColor='#355878';
const headers=['配置对象','字段名称','修改值','导出原值','Lua类型','填写说明','配置字段路径','代码文件相对路径','编辑状态'];
for(const name of sheets){
 const list=records.filter(x=>x.sheet===name),sh=wb.worksheets.add(name);sh.showGridLines=false;
 sh.getRange('A1:I1').values=[headers];
 const matrix=list.map(r=>[r.object,r.label,r.value,r.value,r.type,r.note,r.path,r.file,r.readOnly?'只读':'可修改']);
 // Text formatting is set before writing so long decimal strings remain text.
 sh.getRange('C2:D'+(list.length+1)).setNumberFormat('@');
 sh.getRange('A2:I'+(list.length+1)).values=matrix;
 sh.getRange('A1:I'+(list.length+1)).format.font={name:'Microsoft YaHei',size:10,color:'#243247'};
 sh.getRange('A1:I1').format.fill='#355878';sh.getRange('A1:I1').format.font={name:'Microsoft YaHei',size:10,bold:true,color:'#FFFFFF'};
 sh.getRange('A1:I1').format.horizontalAlignment='center';sh.getRange('A1:I1').format.rowHeight=32;
 sh.getRange('A2:I'+(list.length+1)).format.rowHeight=26;
 for(const [c,w] of [['A',25],['B',33],['C',46],['D',46],['E',13],['F',58],['G',84],['H',40],['I',12]])sh.getRange(c+':'+c).format.columnWidth=w;
 sh.getRange('C2:C'+(list.length+1)).format.fill='#FFF2CC';
 sh.getRange('D2:E'+(list.length+1)).format.fill='#F0F2F5';
 sh.getRange('G2:I'+(list.length+1)).format.fill='#F0F2F5';
 sh.freezePanes.freezeRows(1);sh.freezePanes.freezeColumns(2);
 sh.tables.add('A1:I'+(list.length+1),true,'Config'+sheets.indexOf(name));
 for(let i=0;i<list.length;i++){
  const r=list[i],row=i+2;
  if(r.readOnly){sh.getRange('C'+row).format.fill='#E2E6EB';sh.getRange('C'+row).format.font.color='#697587';}
  if(r.type==='number'){sh.getRange('C'+row+':D'+row).setNumberFormat(Number.isInteger(r.value)?'0':'0.###############');}
  if(r.type==='boolean'&&!r.readOnly)sh.getRange('C'+row).dataValidation={rule:{type:'list',values:['true','false']}};
 }
 sh.tabColor=name==='系统只读'?'#808995':'#B69552';
}
wb.recalculate();
console.log((await wb.inspect({kind:'sheet',include:'id,name',maxChars:3000})).ndjson);
console.log((await wb.inspect({kind:'match',searchTerm:'#REF!|#DIV/0!|#VALUE!|#NAME\\?|#NUM!|#N/A|#SPILL!',options:{useRegex:true,maxResults:10},maxChars:1000})).ndjson);
await fs.writeFile(path.join(support,'GameConfig.source.lua'),bytes);
await fs.writeFile(path.join(support,'baseline.json'),JSON.stringify({version:1,project,relative,hash,date:'2026-10-30',records},null,2));
const output=path.join(out,'游戏配置数值调整表.xlsx');
await (await SpreadsheetFile.exportXlsx(wb)).save(output);
for(const name of ['使用说明',...sheets]){
 const blob=await wb.render({sheetName:name,range:name==='使用说明'?'A1:B8':'A1:F11',scale:1,format:'png'});
 await fs.writeFile(path.join(support,'preview-'+name+'.png'),new Uint8Array(await blob.arrayBuffer()));
}
if(crypto.createHash('sha256').update(await fs.readFile(sourceFile)).digest('hex')!==hash)throw Error('Source changed during export');
console.log(JSON.stringify({output,hash,total:records.length,editable,sheets:sheets.map(s=>[s,records.filter(r=>r.sheet===s).length])}));
