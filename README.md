# shared-workflows

Current workflows:
* Serverless node deploy

# How to use it

#### Serverless node deploy

* Make sure that serverless is installed as NPM dependency 
* NPM script contains following scripts in `package.json` - `deploy:{STAGE}`,  example:
```yaml
  "scripts": {
    "deploy:dev": "serverless deploy -s dev",
    "deploy:qa": "serverless deploy -s qa",
    "deploy:prod": "serverless deploy -s prod"
  }
```
* Add shared job to workflow definition in `.github/workflows/` dir. Example job definition:
```yaml
jobs:
  deploy:
    uses: Tradeswell/shared-workflows/.github/workflows/serverless_node_deploy.yml@main
    with:
      # The environment to deploy to. Corresponds to the equivalent npm `deploy:*` script
      stage: dev 
      # Optional override of the node version to use when building/deploying
      node-version: 14.x
      # Optional override of the working directory. Useful for selecting a single project from a monorepo.
      # Default is the root of the repo.
      working-directory: ./foo/
    secrets:
      # Used to connect to the AWS API and trigger deployments
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      # Used for notification of CI/CD success or failure
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```

* Example full workflow definition:
```yaml
name: CD/CI
on:
  push:
    branches: [ main ]
    paths-ignore:
      - '**/README.md'
      - '.gitignore'
      - 'docs/**'

  pull_request:
    branches: [ main ]
    paths-ignore:
      - '**/README.md'
      - '.gitignore'
      - 'docs/**'

  release:
    types:
      - published

jobs:
  deploy-qa:
    # Only deploy off the main branch
    if: github.ref == 'refs/heads/main'
    uses: Tradeswell/shared-workflows/.github/workflows/serverless_node_deploy.yml@main
    with:
      stage: 'qa'
      node-version: 14.x
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}

  deploy-prod:
    # Only deploy for releases
    if: ${{ github.event_name == 'release' }}
    uses: Tradeswell/shared-workflows/.github/workflows/serverless_node_deploy.yml@main
    with:
      stage: 'prod'
      node-version: 14.x
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```