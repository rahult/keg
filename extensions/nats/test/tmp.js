'use strict';
// A folder of a test's own in the temporary directory, removed with
// everything in it when the test's process ends, passed or failed.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const made = [];
process.on('exit', () => {
  for (const dir of made) fs.rmSync(dir, { recursive: true, force: true });
});

/** A new folder whose name begins with `prefix`, gone when the process ends. */
function tmp(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  made.push(dir);
  return dir;
}

module.exports = { tmp };
