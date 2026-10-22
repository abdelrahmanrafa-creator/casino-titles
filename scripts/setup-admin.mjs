import {randomBytes,randomUUID,createHash} from 'node:crypto';
import {writeFile,access} from 'node:fs/promises';
const secretFile=new URL('../.admin-access.local.txt',import.meta.url),configFile=new URL('../.admin-bootstrap.local.json',import.meta.url);
try{await access(secretFile);throw new Error('An admin access file already exists. Keep it; rotate through the protected panel.');}catch(error){if(error.code!=='ENOENT')throw error;}
const code=randomBytes(32).toString('base64url'),salt=randomUUID(),hash=createHash('sha256').update(salt+code).digest('hex');
await writeFile(secretFile,`CASINO & TITLES — ACCÈS ADMINISTRATEUR\n\nAdresse : /admin\nCode secret : ${code}\n\nConnectez-vous d’abord avec votre compte Casino & Titles confirmé.\nLe premier compte qui prouve ce code peut activer l’administration, uniquement tant qu’aucun administrateur n’existe.\nEnsuite, un rôle administrateur ET le code sont requis. Les sessions durent 30 minutes.\nConservez ce fichier en privé. Il est exclu de Git et du site publié.\n`,{flag:'wx',mode:0o600});
await writeFile(configFile,JSON.stringify({salt,code_hash:hash},null,2),{flag:'wx',mode:0o600});
console.log('Admin secret generated in .admin-access.local.txt; hash configuration in .admin-bootstrap.local.json. No secret printed.');
