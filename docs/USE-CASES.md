# Use Cases

MacVigil is for work that should continue after the user stops actively interacting with the Mac.

The long-term product goal is to identify the actual job and protect it only as long as necessary.

## AI coding agents

Examples:

- implement a feature while you step away
- refactor a large repository
- generate or repair tests
- run repeated build/test/fix loops
- analyze a large codebase
- generate documentation
- perform local code review/static analysis
- run multiple local agents
- execute long tool-use workflows

Ideal future MacVigil behavior:

```text
Agent starts → Vigil starts → display may go dark → agent exits → Vigil ends
```

## Local AI and inference

Examples:

- Ollama
- LM Studio
- MLX workflows
- llama.cpp
- local inference servers
- embedding generation
- RAG indexing
- batch inference
- image generation
- speech-to-text
- text-to-speech
- model conversion/quantization
- model downloads
- evaluation suites

Useful future triggers:

- process exists
- local API port is listening
- active requests continue
- job queue is non-empty

## Builds and test suites

Examples:

- Xcode/Swift builds
- Rust compilation
- C/C++ compilation
- Node/TypeScript builds
- Android/Gradle builds
- Python package builds
- monorepo operations
- unit tests
- integration tests
- end-to-end tests
- static analysis
- dependency updates

Best future interaction:

```sh
macvigil run -- <build-or-test-command>
```

MacVigil should release protection as soon as the command exits.

## Development servers

Examples:

- Next.js/Vite
- Rails
- Django/FastAPI/Flask
- Node/Express
- local databases
- Redis
- Elasticsearch
- MCP servers
- local model APIs
- webhook development servers

Potential trigger:

```text
Keep Vigil while localhost:3000 is listening
```

## Containers and local infrastructure

Examples:

- Docker containers
- Docker Compose projects
- local Kubernetes
- Podman
- database containers
- local queues/brokers
- development stacks

Potential future behavior:

```text
Compose project starts → Vigil protects runtime → project stops → normal sleep restored
```

## Remote access

Examples:

- SSH
- Tailscale
- VPN-based access
- macOS Screen Sharing
- remote desktop
- VS Code remote development
- remote terminal sessions
- temporary Mac-as-a-server use

Remote access fails if the machine unexpectedly sleeps. MacVigil can keep the runtime reachable while allowing a local display to remain dark.

## Downloads, uploads, and synchronization

Examples:

- AI model downloads
- large Git clones / Git LFS
- game/software downloads
- cloud uploads
- NAS transfers
- `rsync`
- `scp`
- SFTP
- large browser downloads
- iCloud/Drive/Dropbox synchronization
- data-set transfers

Future goal: protect only while the actual transfer is active rather than using a long guessed timer.

## Backups and migrations

Examples:

- Time Machine
- NAS backups
- external-drive copies
- encrypted archives
- cloud backup
- home-directory migration
- large restore operations
- photo-library migration

## Creative workflows

### Video

- rendering
- exporting
- transcoding
- proxy generation
- stabilization
- AI enhancement
- batch conversion

### 3D

- Blender renders
- simulations
- baking
- animation export
- texture generation

### Photo

- Lightroom exports
- RAW conversion
- batch resize/processing
- panorama generation
- AI denoise

### Audio

- long exports
- stem rendering
- podcast processing
- sample conversion
- recording sessions

These workloads often need the machine awake but do not require the display to remain bright.

## Data science and research

Examples:

- Jupyter notebooks
- Python/R analysis
- MATLAB
- numerical simulations
- ETL/data cleaning
- large CSV/Parquet conversion
- statistics
- bioinformatics
- optimization
- embeddings
- local model training/evaluation
- long web/data collection tasks

## Self-hosting and home lab

Examples:

- local web service
- media server
- development database
- home automation helper
- dashboard
- private API
- build runner
- local AI endpoint
- file server

Mac mini systems are naturally suited to this, but MacBooks are also frequently used as temporary servers during development or travel.

## Networking and diagnostics

Examples:

- SSH tunnels
- VPN tunnels
- reverse proxies
- packet capture
- network monitoring
- large transfers
- temporary gateway/proxy tasks

## Presentations and displays

These are an important exception to the power-first default because the display itself is required.

Examples:

- presentation
- kiosk
- dashboard
- product demo
- conference booth
- monitoring screen
- classroom demo

Use **Full Awake**, not Compute Guard.

## Recording and streaming

Examples:

- livestream
- screen recording
- audio capture
- podcast recording
- OBS session
- long webinar
- device/data capture

Unexpected system sleep can interrupt or corrupt the session.

## Hardware/device workflows

Examples:

- external SSD copy
- camera import
- audio interface recording
- serial device communication
- microcontroller development
- firmware flashing workflows
- data acquisition
- 3D-printer control software

Future device-connected triggers may be useful for some of these workflows.

## The common pattern

Almost every scenario can be reduced to four questions:

1. **What job needs to stay alive?**
2. **What resources does that job need?**
3. **When is the job actually finished?**
4. **What safety reserve should remain for battery and thermals?**

MacVigil's roadmap is designed around answering those questions directly instead of simply setting a long “don't sleep” timer.
