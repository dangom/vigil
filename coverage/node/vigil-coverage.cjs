// vigil: note which functions of the project a Node program ran.
//
// Node loads this before the program, when NODE_OPTIONS says to --require it.
// bin/vigil-shell says so for the commands an agent runs, when that has been
// asked for (`vigil coverage on'), and says in VIGIL_COVERAGE_RUN where to
// write.  At exit, the functions of files under the project that were called
// are written there as JSON:
//
//     {"files": {"/abs/path/x.js": ["f", "g"]}}
//
// V8 itself is asked which functions ran, and only whether they did: at
// exit, for what it happens to know (its "best effort" coverage).  It is not
// told to count anything as the program runs -- that would take the counts
// away from whoever else asks for them, such as a test runner measuring its
// own coverage -- so a function V8 has since thrown away can be missed.
// Nothing is printed, and nothing here may make the program fail: whatever
// goes wrong, the program runs as if this were not here.
'use strict';
try {
  const run = process.env.VIGIL_COVERAGE_RUN;
  if (run) {
    const fs = require('node:fs');
    const path = require('node:path');
    const url = require('node:url');
    const inspector = require('node:inspector');
    const threads = require('node:worker_threads');

    // The project: the repository the program was started in, else there.
    const start = fs.realpathSync(process.cwd());
    let root = start;
    for (;;) {
      if (fs.existsSync(path.join(root, '.git'))) break;
      const parent = path.dirname(root);
      if (parent === root) { root = start; break; }
      root = parent;
    }
    const prefix = root.endsWith(path.sep) ? root : root + path.sep;
    const apart = path.sep + 'node_modules' + path.sep;

    process.on('exit', () => {
      try {
        const session = new inspector.Session();
        session.connect();
        session.post('Profiler.getBestEffortCoverage', (error, taken) => {
          try {
            if (error || !taken) return;
            const files = {};
            for (const script of taken.result) {
              if (!script.url.startsWith('file://')) continue;
              let file = url.fileURLToPath(script.url);
              // Most of what a program loads is somebody else's: passed over
              // before anything is asked of the disk.
              if (file.includes(apart)) continue;
              try { file = fs.realpathSync(file); } catch { /* as it is named */ }
              if (!file.startsWith(prefix) || file.includes(apart)) continue;
              const names = new Set();
              for (const fn of script.functions) {
                if (fn.functionName && fn.ranges[0] && fn.ranges[0].count > 0) {
                  names.add(fn.functionName);
                }
              }
              files[file] = [...names].sort();
            }
            if (Object.keys(files).length === 0) return;
            fs.mkdirSync(run, { recursive: true, mode: 0o700 });
            for (const [name, text] of [['command.txt', process.env.VIGIL_COVERAGE_COMMAND],
                                        ['cwd.txt', process.env.VIGIL_COVERAGE_CWD]]) {
              const where = path.join(run, name);
              if (text !== undefined && !fs.existsSync(where)) fs.writeFileSync(where, text);
            }
            const name = `node-${process.pid}-${threads.threadId}.json`;
            fs.writeFileSync(path.join(run, name + '.tmp'), JSON.stringify({ files }));
            fs.renameSync(path.join(run, name + '.tmp'), path.join(run, name));
          } catch { /* nothing is written */ }
        });
      } catch { /* nothing is written */ }
    });
  }
} catch { /* the program runs as if this were not here */ }
