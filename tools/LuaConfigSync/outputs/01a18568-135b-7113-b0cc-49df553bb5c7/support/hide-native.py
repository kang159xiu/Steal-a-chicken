import pathlib,json,copy,zipfile,xml.etree.ElementTree as E,posixpath,hashlib
from openpyxl import load_workbook
from openpyxl.utils import get_column_letter
d=pathlib.Path(__file__).parent;p=d.parent
before=load_workbook(d/'before-hide.xlsx'); m=json.loads((d/'hide-manifest.json').read_text(encoding='utf-8'))
edits={(e['sheet'],e['cell']):e['value'] for e in m['edits'] if e['sheet']=='使用说明'}
hidden={}
for s in before:
 if s.title in ['使用说明','字段映射']:continue
 for row in s:
  for c in row:
   v=c.value
   if not isinstance(v,str):continue
   if v=='原值' or v.endswith('·原值'):hidden.setdefault(s.title,set()).add(c.column)
   if v=='修改值' or v.endswith('·修改值'):edits[s.title,c.coordinate]='配置值' if v=='修改值' else v.replace('·修改值','')
 # Preserve the lower vertical table's object identity when column B is hidden.
 if s.title=='玩法参数':
  active=False
  for row in s:
   if row[0].value=='用途 / 系统':active=True;continue
   if active and row[0].value is not None and row[1].value is not None:edits[s.title,row[0].coordinate]=str(row[0].value)+' / '+str(row[1].value)
ns='http://schemas.openxmlformats.org/spreadsheetml/2006/main';N={'s':ns};q=lambda x:'{'+ns+'}'+x
with zipfile.ZipFile(d/'before-hide.xlsx') as z:
 payload={i.filename:z.read(i.filename) for i in z.infolist()}
 wb=E.fromstring(payload['xl/workbook.xml']);rels={r.attrib['Id']:r.attrib['Target'] for r in E.fromstring(payload['xl/_rels/workbook.xml.rels'])}
 for sh in wb.findall('s:sheets/s:sheet',N):
  name=sh.attrib['name'];t=rels[sh.attrib['{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id']];f=t.lstrip('/') if t.startswith('/') else posixpath.normpath('xl/'+t)
  changes={cell:v for (s,cell),v in edits.items() if s==name};hide=hidden.get(name,set())
  if not changes and not hide:continue
  root=E.fromstring(payload[f]);data=root.find('s:sheetData',N);cells={c.attrib['r']:c for c in root.findall('s:sheetData/s:row/s:c',N)}
  for addr,v in changes.items():
   c=cells[addr];c.set('t','inlineStr')
   for child in list(c):c.remove(child)
   E.SubElement(E.SubElement(c,q('is')),q('t')).text=v
  if hide:
   cols=root.find('s:cols',N)
   assert cols is not None
   for c in list(cols):
    cols.remove(c)
    for idx in range(int(c.attrib['min']),int(c.attrib['max'])+1):
     n=copy.deepcopy(c);n.set('min',str(idx));n.set('max',str(idx))
     if idx in hide:n.set('hidden','1')
     cols.append(n)
   for pane in root.findall('s:sheetViews/s:sheetView/s:pane',N):pane.set('topLeftCell','C5' if name not in ['ID与资源配置','系统配置（只读）'] else 'B5')
  payload[f]=E.tostring(root,encoding='utf-8',xml_declaration=True)
 # Keep native table header names consistent; do not alter filter ranges or table identities.
 for f,raw in list(payload.items()):
  if not f.startswith('xl/tables/') or not f.endswith('.xml'):continue
  root=E.fromstring(raw);changed=False
  for c in root.findall('s:tableColumns/s:tableColumn',N):
   v=c.attrib['name']
   if v=='修改值' or v.endswith('·修改值'):c.set('name','配置值' if v=='修改值' else v.replace('·修改值',''));changed=True
  if changed:payload[f]=E.tostring(root,encoding='utf-8',xml_declaration=True)
 temp=d/'hide-final.xlsx'
 with zipfile.ZipFile(temp,'w',zipfile.ZIP_DEFLATED) as output:
  for info in z.infolist():output.writestr(info,payload[info.filename])
after=load_workbook(temp)
for s in before:
 a=after[s.title]
 for row in s:
  for c in row:
   assert a[c.coordinate].value==edits.get((s.title,c.coordinate),c.value),(s.title,c.coordinate)
   assert a[c.coordinate].number_format==c.number_format,(s.title,c.coordinate)
 for idx in hidden.get(s.title,set()):assert a.column_dimensions[get_column_letter(idx)].hidden
 assert len(a.tables)==len(s.tables)
 assert len(a.data_validations.dataValidation)==len(s.data_validations.dataValidation)
mapping=json.loads((d/'reformat-mapping.json').read_text(encoding='utf-8'))
for r in mapping['records']:
 a=after[r['sheet']][r['modifiedCell']];b=before[r['sheet']][r['modifiedCell']]
 assert a.value==b.value and a.data_type==b.data_type,r['path']
assert after['鸡与蛋价值']['C5'].value==100 and after['鸡与蛋价值']['E5'].value==100 and after['鸡与蛋价值']['E6'].value==200 and after['商店价格与收益']['C5'].value=='30'
assert (p/'游戏经济与配置调整表.xlsx').read_bytes()==(d/'before-hide.xlsx').read_bytes(),'Concurrent edit'
temp.replace(p/'游戏经济与配置调整表.xlsx')
print(json.dumps({'fields_verified':len(mapping['records']),'user_edits_preserved':4,'hidden_columns':sum(len(v) for v in hidden.values()),'tables_and_validations_preserved':True}))
