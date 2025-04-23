#  WP HubStack

A next generation, all-in-one, developer stack equiped with interoperable command and control capabilities!  For it, or contribute!
... well some day.  Today this is just a group of scripts useful for cross-server bulk Docker and WordPress Management.


## Mission
- Create a CI/CD Deployment Pipeline for WordPress websites Core WordPress
  - WordPress Docker Images 


## Features (Stakeholder Language)
- Build & Deploy Custom WordPress Container Images to your own Registry
- Generate Static Sites from WP Sites & deploy to 
- Developer can quickly make changes
- Choose to Reconsile (upsert) database data during deployment
- Perform WP-CLI commands locally, or remotely
- Bulk Actions


## Features (Techy Language)
- SSG Building & Deployment
- Automated Testing
- Granular Observability
- Built In Web Server
- Configurable Logging
- AI Integration / Generation
- Decoupled Multiprotocol IO Pipeline Configurations (CI/CD)
  - rsync
  - rcopy
  - git
- Stage Development Environments from Production Environments
- Deploy WordPress Websites to Production Environments
- Opinionated Dev Container
- 

## User Stories

Developers should be abile to easily
- Easily pull a WordPress Website from any environment and stage it locally for development
- Add working sites to git repositories


### Developer Tools

- WP-ClI
- WP-Scan


### Configurable Targets

Currently using typescript to represent a proof of concept/anatomy/outline of interoperability requirements.

```TS
// Options for each website/target
enum FileTransferStrategy { fs, s3, ftp, sftp, rsync, rcopy, git, registry }
enum DatabaseTransferStrategy { skip, replace, upsert }
enum ServerType { local, development, testing, staging, production }
enum Database { mysql, maria }

interface Server: {
    name: string;
    type: ServerType;
    database: Database;
    domain: string;
    url: string;
    pull?: TransferOptions;
    push?: TransferOptions;
}

interface ProxyOptions {
    host: string;
    port: number;
}

interface TransferOptions {
    protocol: TransferProtocol;
    filesystem: FileTransferOptions;
    options?: {
        host: string;
        port: number;
    };
}

interface ExtractionOptions extends TransferOptions { }

interface StagingOptions extends TransferOptions { }

interface DeploymentOptions extends TransferOptions { }

interface FileTransferProtocol extends TransferProtocol {
    host: string;
    port: number;
}

interface DatabaseTransferStrategy {
    type: Database;
    options?: {
        user: string;
        password: string;
        host: string;
        port: number;
    };
}
```

## Env Settings
- 

## TODO

- Have `new-site.sh` Look for .sql files in the downloaded/extracted archive vs look for the one from WPEngine (the use case we needed)


## Scripts

`new-site.sh`
- Download and extract a WordPress site from WPEngine.
- Create a new Docker container with the extracted site.