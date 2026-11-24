"""vigil: note which functions of the project a Python program ran.

Python imports a module of this name as it starts, from wherever PYTHONPATH
says.  bin/vigil-shell puts this directory there for the commands an agent
runs, when that has been asked for (`vigil coverage on'), and says in
VIGIL_COVERAGE_RUN where to write.  At exit, the functions of files under
the project that were called are written there as JSON:

    {"files": {"/abs/path/x.py": ["f", "Class.method", "<module>"]}}

Only that they were called, once each: after its first call a function is
not watched (sys.monitoring, Python 3.12 and later; on an older Python
nothing is done, since watching every call there would slow the program).
Nothing is printed, and nothing here may make the program fail: whatever
goes wrong, the program runs as if this were not here.
"""

import os
import sys


def _vigil_coverage():
    run = os.environ.get("VIGIL_COVERAGE_RUN")
    monitoring = getattr(sys, "monitoring", None)
    if not run or monitoring is None:
        return

    # The project: the repository the program was started in, else there.
    start = os.path.realpath(os.getcwd())
    root = start
    while True:
        if os.path.exists(os.path.join(root, ".git")):
            break
        parent = os.path.dirname(root)
        if parent == root:
            root = start
            break
        root = parent
    prefix = root.rstrip(os.sep) + os.sep
    apart = tuple(os.sep + name + os.sep for name in
                  ("site-packages", "dist-packages", ".venv", "venv", ".pixi",
                   ".tox", "node_modules"))

    seen = {}
    wanted = {}

    def file_of(name):
        known = wanted.get(name)
        if known is None:
            if name.startswith("<"):    # <frozen os>, <string>: no file
                wanted[name] = False
                return False
            path = name if os.path.isabs(name) else os.path.join(start, name)
            path = os.path.realpath(path)
            known = wanted[name] = (
                path if path.startswith(prefix)
                and not any(part in path for part in apart) else False)
        return known

    def started(code, _offset):
        try:
            path = file_of(code.co_filename)
            if path:
                seen.setdefault(path, set()).add(code.co_qualname)
        except Exception:
            pass
        return monitoring.DISABLE

    # Not the debugger's, the profiler's or coverage.py's: one nobody claims.
    tool = None
    for candidate in (3, 4):
        try:
            monitoring.use_tool_id(candidate, "vigil")
            tool = candidate
            break
        except ValueError:
            continue
    if tool is None:
        return
    monitoring.register_callback(tool, monitoring.events.PY_START, started)
    monitoring.set_events(tool, monitoring.events.PY_START)

    def write():
        try:
            if not seen:
                return
            import json
            os.makedirs(run, mode=0o700, exist_ok=True)
            for name, text in (("command.txt", os.environ.get("VIGIL_COVERAGE_COMMAND")),
                               ("cwd.txt", os.environ.get("VIGIL_COVERAGE_CWD"))):
                path = os.path.join(run, name)
                if text is not None and not os.path.exists(path):
                    with open(path, "w") as f:
                        f.write(text)
            path = os.path.join(run, "python-%d.json" % os.getpid())
            with open(path + ".tmp", "w") as f:
                json.dump({"files": {name: sorted(names)
                                     for name, names in seen.items()}}, f)
            os.replace(path + ".tmp", path)
        except Exception:
            pass

    import atexit
    atexit.register(write)


def _vigil_next():
    """Run the sitecustomize this one stands in front of, if there is one."""
    here = os.path.dirname(os.path.abspath(__file__))
    for entry in sys.path:
        try:
            directory = os.path.abspath(entry or os.curdir)
            if directory == here:
                continue
            candidate = os.path.join(directory, "sitecustomize.py")
            if os.path.isfile(candidate):
                import importlib.util
                spec = importlib.util.spec_from_file_location("sitecustomize", candidate)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                return
        except Exception:
            return


try:
    _vigil_coverage()
except Exception:
    pass
_vigil_next()
