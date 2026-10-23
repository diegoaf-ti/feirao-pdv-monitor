'use strict';

// Ferramenta offline, nunca executada pelo startup nem pelo atualizador.
// O estado não pode ser recriado com contextos Guacamole antigos em uso.
const fs = require('node:fs');
const path = require('node:path');
const initialize = (target, confirmed) => {
  if (confirmed !== '--guacamole-and-guacd-stopped-json-key-rotated') throw new Error('OfflineMaintenanceConfirmationRequired');
  if (!path.isAbsolute(target)) throw new Error('AbsolutePathRequired');
  const directory = fs.lstatSync(path.dirname(target));
  if (!directory.isDirectory() || (process.platform !== 'win32' && ((directory.mode & 0o077) || directory.uid !== process.getuid()))) throw new Error('PrivateOwnedDirectoryRequired');
  const descriptor = fs.openSync(target, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
  try { fs.writeFileSync(descriptor, JSON.stringify({ schemaVersion: 2, leases: [], usedPorts: [] })); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
};
if (require.main === module) {
  try { initialize(process.argv[2], process.argv[3]); process.stdout.write('Estado inicial offline criado. Piloto continua desativado.\n'); }
  catch { process.stderr.write('Estado não criado. Verifique manutenção offline, diretório privado e ausência de journal anterior.\n'); process.exitCode = 1; }
}
module.exports = { initialize };
