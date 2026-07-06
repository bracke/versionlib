# Transports

`version` supports local paths, `file://`, HTTP(S), and SSH within the documented scope. Unknown schemes are rejected before execution.

## Local paths and file URLs

Plain paths such as `../repo` and `file://` URLs use the local transport. They support deterministic clone/fetch/push without public network access. Local `push --tags` is supported through this transport. Unsupported shallow-depth requests fail rather than silently producing a different kind of clone.

`file://` paths percent-decode escaped path bytes such as `%20` before filesystem access. `file://localhost/...` is treated as a local path, while other file URL authorities are rejected instead of being interpreted as relative paths. Malformed percent escapes such as `%ZZ` or truncated escapes are rejected before clone target creation or remote mutation. Configured `file://` remote URLs remain stored as configured, so `remote get-url` preserves the encoded URL while later fetch/push operations use the decoded local path for access.

```sh
version clone ../source clone
version remote add origin ../remote.git
version fetch origin
version push origin main
```

## HTTP and HTTPS

HTTP(S) remotes use Git smart protocol upload-pack/receive-pack behavior through `Version.Transport.Http`, `Version.Pkt_Line`, `Version.Upload_Pack`, and `Version.Receive_Pack`. `Version.Transport.Http` uses `HttpClient` streaming with HTTPS HTTP/2 ALPN enabled and HTTP/1.1 fallback before request bytes are sent; plain `http://` remains HTTP/1.1 because h2c is not implemented by the backend. Branch push uses receive-pack; `push --tags` is intentionally local-only in this release and rejects HTTP(S) remotes before upload. TLS trust belongs to the configured HTTP/TLS backend. Credentials must not leak across origins. Normal tests should not require public internet access.

```sh
version clone https://example.invalid/team/project.git project
```

## SSH

SSH remotes use URL parsing, direct argv construction, and subprocess pipe streaming for a configured system SSH client. `version` does not shell-interpolate SSH commands. SSH fetch, clone, remote prune, and push use upload-pack/receive-pack through this transport boundary; fetch/clone support depth-limited shallow negotiation when the server advertises the `shallow` capability and annotated tag following when it advertises `include-tag`. Branch push uses receive-pack; `push --tags` is intentionally local-only in this release and rejects SSH remotes before upload.

```text
ssh://host/path/to/repo.git
git@host:path/to/repo.git
```

Host-key verification, key selection, passphrase prompts, and agent behavior belong to the SSH client.

## Unsupported schemes

Schemes such as `ftp://` or custom helpers are unsupported unless a future phase documents and tests them.

## Phase 41 HTTP fetch streaming

`Version.Fetch` no longer collects the full smart-HTTP upload-pack response before demuxing.  The HTTP response stream is consumed chunk by chunk through the same `HttpClient` streaming API for HTTP/1.1 and HTTPS HTTP/2, pkt-lines are parsed incrementally, side-band channel 1 data is written to the temporary pack file, and shallow metadata is retained separately.  The temporary pack is closed before indexing so verification still runs over the complete downloaded pack.

## Phase 41 HTTP push request assembly

HTTP receive-pack still posts a single request payload because the currently used HTTP client request API is payload-oriented.  The push path now builds that payload from the temporary pack file directly, rather than reading the whole pack into one buffer and then copying it into a second combined request.  The temporary pack remains on disk until report-status succeeds or the push path cleans up after failure.
