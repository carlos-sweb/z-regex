import fs from 'fs';
const rows=fs.readFileSync(process.argv[2],'utf8').trim().split('\n').map(l=>l.split('\t'));
const c={vm:0,bt:0,neither:0,noarb:0}; const pats={vm:new Set(),bt:new Set(),neither:new Set(),noarb:new Set()};
for(const [f,h,sub,idx,st,vm,bt] of rows){
  const src=Buffer.from(h,'hex').toString('utf8');
  const s=String.fromCharCode(...sub.split(',').filter(x=>x).map(x=>parseInt(x,16)));
  let re; try{re=new RegExp(src,f+(st==='1'?'y':'g'));}catch(e){c.noarb++;pats.noarb.add(f+'/'+src);continue;}
  re.lastIndex=+idx; const m=re.exec(s);
  let v='null'; if(m){const a=[];for(let k=0;k<m.length;k++){ if(m[k]===undefined){a.push(-1,-1);continue;}
    // compute indices via hasIndices
  } }
  let re2=new RegExp(src,f+'d'+(st==='1'?'y':'g')); re2.lastIndex=+idx; const m2=re2.exec(s);
  if(m2){v=m2.indices.map(x=>x?x.join(','):'-1,-1').join(',');}
  const k = v===vm? 'vm' : v===bt? 'bt':'neither';
  c[k]++; pats[k].add(f+'/'+src);
}
console.log(JSON.stringify(c)); for(const k in pats) console.log(k,pats[k].size,[...pats[k]].slice(0,15).join(' | '));
