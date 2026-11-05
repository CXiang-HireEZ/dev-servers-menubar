# DevServers

A macOS menu bar app that lists the dev servers running on your machine and stops them in one click.

For each listening port it shows:

- the repo, and the worktree if the server runs in a git worktree
- the branch
- the listening process and the command that started it, plus the full process chain
- where it was launched from (cmux, tmux, VS Code, Ghostty, and so on)
- the T3 Code thread that started it, read from `T3CODE_THREAD_ID`, or the thread that owns its T3 worktree

Rows are grouped by repo.

## Use

- Click a row to open `http://localhost:<port>`.
- Hold ⌥ and click a row to stop that server. This stops its whole process tree with SIGTERM, then sends SIGKILL to anything still running after 3 s.
- Open a row's submenu to stop the server, open it in the browser, open its T3 thread, reveal it in Finder, or copy any detail.

## Build

Requires the Xcode Command Line Tools (`swiftc`). Works on macOS 14+.

```sh
./build.sh            # builds build/DevServers.app
./build.sh --install  # also copies it to ~/Applications and launches it
```

## CLI

```sh
~/Applications/DevServers.app/Contents/MacOS/DevServers --list        # dev servers
~/Applications/DevServers.app/Contents/MacOS/DevServers --list --all  # every listening process
~/Applications/DevServers.app/Contents/MacOS/DevServers --stop 8084   # stop the server on a port
```
