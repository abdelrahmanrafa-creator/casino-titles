import {spawn} from 'node:child_process';
import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve,join} from 'node:path';
// Credentials come from PGHOST/PGPORT/PGDATABASE/PGUSER and PGPASSFILE (or PGPASSWORD).
// Never put a connection string or password in the process arguments or manifest.
const directory=resolve(process.argv[2]||'backups');await mkdir(directory,{recursive:true});
const stamp=new Date().toISOString().replaceAll(':','-'),file=join(directory,`casino-titles-${stamp}.dump`);
const child=spawn('pg_dump',['--format=custom','--no-owner','--table=public.ct_*','--file',file],{stdio:['ignore','inherit','inherit'],shell:false});
child.on('error',()=>{console.error('pg_dump unavailable. Install official PostgreSQL client tools and configure PG environment variables.');process.exitCode=1;});
child.on('exit',async code=>{if(code!==0){process.exitCode=code||1;return;}
 const bytes=await readFile(file);await writeFile(`${file}.json`,JSON.stringify({created_at:new Date().toISOString(),file,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex'),scope:'public.ct_*',requires:'Matching auth.users identities; see BACKUPS.md'},null,2));
 console.log(`Backup verified: ${file}`);
});
