// One-time setup for the /admin page (v0.35). Run on YOUR computer, never share the output.
//   node tools/admin-setup.mjs            -> prints the 3 secrets + the commands to store them
//   node tools/admin-setup.mjs --put      -> also stores them with `wrangler secret put` (add --env staging for the test copy)
// Rotate any time by running it again (new password/code; old sessions stop working because the session secret changes).
import { pbkdf2Sync, randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import readline from 'node:readline';

const args = process.argv.slice(2), put = args.includes('--put'), env = args.includes('--env') ? args[args.indexOf('--env') + 1] : '';
const b64u = b => Buffer.from(b).toString('base64url');
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const b32 = buf => { let bits = '', o = ''; for (const x of buf) bits += x.toString(2).padStart(8, '0'); for (let i = 0; i < bits.length; i += 5) o += B32[parseInt(bits.slice(i, i + 5).padEnd(5, '0'), 2)]; return o; };

function ask(q) { // hidden input
  return new Promise(res => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl._writeToOutput = s => { if (s.includes(q)) rl.output.write(s); else rl.output.write(''); };
    rl.question(q, a => { rl.close(); process.stdout.write('\n'); res(a); });
  });
}
const pw = await ask('Choose an admin password (16+ characters, not used anywhere else): ');
const pw2 = await ask('Repeat it: ');
if (pw !== pw2) { console.error('Passwords differ.'); process.exit(1); }
if (pw.length < 16) { console.error('Too short: use at least 16 characters (a few random words is fine).'); process.exit(1); }

const salt = randomBytes(16), ITER = 100000; // Cloudflare Workers allow at most 100000 PBKDF2 iterations
const hash = `pbkdf2$${ITER}$${b64u(salt)}$${b64u(pbkdf2Sync(pw, salt, ITER, 32, 'sha256'))}`;
const totp = b32(randomBytes(20));
const session = b64u(randomBytes(48));
const secrets = { ADMIN_PASSWORD_HASH: hash, ADMIN_TOTP_SECRET: totp, ADMIN_SESSION_SECRET: session };

console.log('\n1) Add this to your authenticator app (Google Authenticator, Aegis, 1Password, ...):');
console.log('   Account: MitroHelper admin   Type: time-based   Secret key:', totp);
console.log('   or open this link on a device that can render a QR: otpauth://totp/MitroHelper:admin?secret=' + totp + '&issuer=MitroHelper\n');

if (put) {
  for (const [k, v] of Object.entries(secrets)) {
    const r = spawnSync('npx', ['wrangler', 'secret', 'put', k, ...(env ? ['--env', env] : [])], { input: v, stdio: ['pipe', 'inherit', 'inherit'], shell: process.platform === 'win32' });
    if (r.status !== 0) { console.error('Failed to store', k); process.exit(1); }
  }
  console.log('\nStored. Now: run supabase/migrate_v14.sql, then `npx wrangler deploy`' + (env ? ' --env ' + env : '') + ', then open /admin.');
} else {
  console.log('2) Store the three secrets (paste the value when wrangler asks):');
  for (const [k, v] of Object.entries(secrets)) console.log(`   npx wrangler secret put ${k}${env ? ' --env ' + env : ''}\n      value: ${v}`);
  console.log('\n3) Run supabase/migrate_v14.sql, then `npx wrangler deploy`, then open /admin.');
}
console.log('\nClear this terminal afterwards. Without all three secrets the /admin page answers 404.');
