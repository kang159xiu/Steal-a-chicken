import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {FileBlob,SpreadsheetFile} from '@oai/artifact-tool';
const dir=path.dirname(fileURLToPath(import.meta.url));
const input=path.join(dir,'../游戏经济与配置调整表.xlsx');
await fs.copyFile(input,path.join(dir,'before-hide.xlsx'));
const wb=await SpreadsheetFile.importXlsx(await FileBlob.load(input));
const edits=[],hidden={};
function edit(sheet,cell,value){wb.worksheets.getItem(sheet).getRange(cell).values=[[value]];edits.push({sheet,cell,value});}
for(let i=0;i<wb.worksheets.items.length;i++){
 const s=wb.worksheets.items[i];if(['使用说明','字段映射'].includes(s.name))continue;
 const range=s.getUsedRange();const values=range.values;
 for(let row=0;row<values.length;row++)for(let c=0;c<(values[row]?.length??0);c++){
  const v=values[row][c];if(typeof v!=='string')continue;
  let n=c+1,col='';while(n){col=String.fromCharCode(65+(n-1)%26)+col;n=Math.floor((n-1)/26);}
  if(v==='原值'||v.endsWith('·原值')){hidden[s.name]??=[];if(!hidden[s.name].includes(c+1))hidden[s.name].push(c+1);}
  if(v==='修改值'||v.endsWith('·修改值'))edit(s.name,col+(row+1),v==='修改值'?'配置值':v.replace('·修改值',''));
 }
}
edit('使用说明','B2','只改黄色数值单元格；原值列已隐藏，灰色项保持原样。');
edit('使用说明','B7','已保留你填写的全部数值；原值在隐藏列及末尾字段映射中保留，导出基线不变。');
edit('使用说明','B10','灰色项为只读提示；未设置工作表密码。需要查看原值时可手动取消隐藏列。');
wb.recalculate();
await(await SpreadsheetFile.exportXlsx(wb)).save(path.join(dir,'hide-authored.xlsx'));
await fs.writeFile(path.join(dir,'hide-manifest.json'),JSON.stringify({edits,hidden},null,2));
console.log(JSON.stringify({edits:edits.length,hidden}));
