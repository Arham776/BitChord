# InnerTubeX Apple integration

Source: https://github.com/MetrolistGroup/innertubex
Pinned revision: a6ca8cb76e9c347d4f21824ca9f19b9db2e5aebd

The local Gradle adapter
adds macOS arm64 alongside upstream's iOS targets, omits Android/JVM publishing
plugins, and embeds the same EJS resources using upstream's generator.
License and source notices are retained.

Apple runtime adapter: the upstream EJS solver runs in JavaScriptCore on one
4 MiB-stack Foundation thread. Upstream extraction and cipher code are retained;
JavaScriptCore replaces QuickJS execution to avoid iOS worker-stack crashes and
reduce current player-script parsing cost. `AppleEjsRuntimeTest` exercises the
embedded EJS bundle with the actual Apple runtime. Runtime errors are categorized
without logging scripts, signed URLs or token payloads.

BitChord supplies upstream's visitor-bound player-request token and video-bound
streaming-data token through an isolated WKWebView. Challenge HTTP uses a public,
cookie-free client; web rendering blocks network loads, matching upstream.
