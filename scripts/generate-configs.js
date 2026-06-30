#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import toml from 'toml';
import yaml from 'js-yaml';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const configDir = path.join(rootDir, 'config');

// Load shared configuration
const sharedConfig = toml.parse(fs.readFileSync(path.join(configDir, 'shared.toml'), 'utf8'));

// Load mac-agent configuration
const macAgentConfig = yaml.load(fs.readFileSync(path.join(configDir, 'mac-agent.yml'), 'utf8'));

const JOBS_CRON_TRIGGERS = ['*/15 * * * *', '0 * * * *'];

function devEmbeddingQueueName() {
  return sharedConfig.prod?.queues?.embedding_queue || 'sky-ai-embeddings-dev';
}

function jobsQueueConsumer(queueName) {
  return {
    queue: queueName,
    max_batch_size: 10,
    max_batch_timeout: 30
  };
}

// Generate Wrangler configurations
function generateWranglerConfig(workerName, mainFile, additionalVars = {}) {
  const config = {
    name: workerName,
    main: mainFile,
    compatibility_date: "2026-03-05",
    compatibility_flags: ["nodejs_compat"],
    workers_dev: true,
    vars: {
      ENVIRONMENT: sharedConfig.shared.environment,
      AIG_ACCOUNT_ID: sharedConfig.shared.aig_account_id,
      AIG_GATEWAY_ID: sharedConfig.shared.aig_gateway_id,
      OPENAI_MODEL: sharedConfig.shared.openai_model,
      OPENAI_EMBEDDING_MODEL: sharedConfig.shared.openai_embedding_model,
      ACCESS_AUTH_ENABLED: sharedConfig.shared.access_auth_enabled,
      ALLOW_API_KEY_BYPASS: sharedConfig.shared.allow_api_key_bypass,
      ...additionalVars
    },
    d1_databases: [{
      binding: "SKY_DB",
      database_name: sharedConfig.shared.dev_database_name,
      database_id: sharedConfig.shared.dev_database_id,
      migrations_dir: "db/migrations"
    }],
    r2_buckets: workerName === 'sky-ai' ? [{
      binding: "SKY_ARTIFACTS",
      bucket_name: sharedConfig.shared.dev_r2_bucket
    }] : undefined,
    vectorize: [{
      binding: "SKY_VECTORIZE",
      index_name: sharedConfig.shared.dev_vectorize_index
    }],
    ai: {
      binding: "AI"
    },
    durable_objects: workerName === 'sky-ai' ? {
      bindings: [{
        name: "BLAWBY_AGENT",
        class_name: "BlawbyAgent"
      }]
    } : undefined,
    migrations: workerName === 'sky-ai' ? [{
      tag: "v1",
      new_sqlite_classes: ["BlawbyAgent"]
    }] : undefined,
    queues: workerName === 'sky-ai' ? {
      producers: [{
        binding: "EMBEDDING_QUEUE",
        queue: devEmbeddingQueueName()
      }]
    } : workerName === 'sky-ai-jobs' ? {
      consumers: [jobsQueueConsumer(devEmbeddingQueueName())]
    } : undefined,
    triggers: workerName === 'sky-ai-jobs' ? {
      crons: JOBS_CRON_TRIGGERS
    } : undefined
  };

  // Add production environment overrides
  config.env = {
    prod: {
      vars: {
        ENVIRONMENT: sharedConfig.prod.environment,
        AIG_ACCOUNT_ID: sharedConfig.shared.aig_account_id,
        AIG_GATEWAY_ID: sharedConfig.shared.aig_gateway_id,
        OPENAI_MODEL: sharedConfig.shared.openai_model,
        OPENAI_EMBEDDING_MODEL: sharedConfig.shared.openai_embedding_model,
        ACCESS_AUTH_ENABLED: sharedConfig.shared.access_auth_enabled,
        ALLOW_API_KEY_BYPASS: sharedConfig.prod.allow_api_key_bypass,
        ...additionalVars
      },
      d1_databases: [{
        binding: "SKY_DB",
        database_name: sharedConfig.prod.database.database_name,
        database_id: sharedConfig.prod.database.database_id,
        migrations_dir: "db/migrations"
      }],
      r2_buckets: workerName === 'sky-ai' ? [{
        binding: "SKY_ARTIFACTS",
        bucket_name: sharedConfig.prod.r2.bucket_name
      }] : undefined,
      vectorize: [{
        binding: "SKY_VECTORIZE",
        index_name: sharedConfig.prod.vectorize.index_name
      }],
      ai: {
        binding: "AI"
      },
      durable_objects: workerName === 'sky-ai' ? {
        bindings: [{
          name: "BLAWBY_AGENT",
          class_name: "BlawbyAgent"
        }]
      } : undefined,
      queues: workerName === 'sky-ai' ? {
        producers: [{
          binding: "EMBEDDING_QUEUE",
          queue: sharedConfig.prod.queues.embedding_queue
        }]
      } : workerName === 'sky-ai-jobs' ? {
        consumers: [jobsQueueConsumer(sharedConfig.prod.queues.embedding_queue)]
      } : undefined,
      triggers: workerName === 'sky-ai-jobs' ? {
        crons: JOBS_CRON_TRIGGERS
      } : undefined
    }
  };

  return config;
}

// Generate main worker config
const mainWorkerConfig = generateWranglerConfig('sky-ai', 'src/worker.ts');
fs.writeFileSync(path.join(rootDir, 'wrangler.toml'), tomlify(mainWorkerConfig));

// Generate API worker config.
// BETTER_AUTH_URL is the public origin ChatGPT uses for OAuth + MCP discovery.
// On workers.dev this is https://sky-ai-api.<your-subdomain>.workers.dev (no trailing slash).
// Set `better_auth_url` under [shared] in config/shared.toml to override the placeholder.
const apiWorkerConfig = generateWranglerConfig('sky-ai-api', 'workers/api/src/worker.ts', {
  WORKERS_AI_EMBEDDING_MODEL: "@cf/baai/bge-base-en-v1.5",
  WORKERS_AI_CHAT_MODEL: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
  VECTOR_DIMENSIONS: "1536",
  BETTER_AUTH_URL: sharedConfig.shared.better_auth_url || "https://sky-ai-api.YOUR-SUBDOMAIN.workers.dev"
});
fs.writeFileSync(path.join(rootDir, 'wrangler.api.toml'), tomlify(apiWorkerConfig));

// Generate Jobs worker config
const jobsWorkerConfig = generateWranglerConfig('sky-ai-jobs', 'workers/jobs/src/worker.ts', {
  WORKERS_AI_EMBEDDING_MODEL: "@cf/baai/bge-base-en-v1.5",
  WORKERS_AI_CHAT_MODEL: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
  VECTOR_DIMENSIONS: "1536"
});
fs.writeFileSync(path.join(rootDir, 'wrangler.jobs.toml'), tomlify(jobsWorkerConfig));

// Generate XcodeGen project configuration
function generateXcodeGenConfig() {
  const config = {
    name: "BlawbyAgent",
    options: {
      bundleIdPrefix: "com.blawby",
      deploymentTarget: {
        macOS: macAgentConfig.build.deployment_target
      },
      xcodeVersion: macAgentConfig.build.xcode_version,
      generateEmptyDirectories: true
    },
    settings: {
      base: {
        SWIFT_VERSION: macAgentConfig.build.swift_version,
        MACOSX_DEPLOYMENT_TARGET: macAgentConfig.build.deployment_target,
        CODE_SIGN_STYLE: macAgentConfig.signing.code_sign_style,
        INFOPLIST_FILE: "BlawbyAgent/Info.plist",
        MARKETING_VERSION: macAgentConfig.app.marketing_version,
        CURRENT_PROJECT_VERSION: macAgentConfig.app.current_project_version
      }
    },
    packages: macAgentConfig.packages,
    targets: {
      BlawbyAgent: {
        type: "application",
        platform: "macOS",
        sources: [
          { path: "Sources/BlawbyAgent" },
          { path: "Resources", buildPhase: "resources" }
        ],
        info: {
          path: "BlawbyAgent/Info.plist",
          properties: {
            LSUIElement: true,
            NSContactsUsageDescription: macAgentConfig.privacy.contacts_usage,
            NSCalendarsFullAccessUsageDescription: macAgentConfig.privacy.calendar_usage,
            NSAppleEventsUsageDescription: macAgentConfig.privacy.apple_events_usage,
            CFBundleIdentifier: macAgentConfig.app.bundle_id,
            CFBundleName: macAgentConfig.app.name,
            CFBundleShortVersionString: "$(MARKETING_VERSION)",
            CFBundleVersion: "$(CURRENT_PROJECT_VERSION)",
            SUFeedURL: macAgentConfig.sparkle.feed_url,
            SUPublicEDKey: macAgentConfig.sparkle.public_ed_key,
            SUEnableAutomaticChecks: macAgentConfig.sparkle.enable_automatic_checks
          }
        },
        dependencies: macAgentConfig.target_dependencies,
        settings: {
          base: {
            DEVELOPMENT_TEAM: macAgentConfig.signing.development_team,
            CODE_SIGN_ENTITLEMENTS: macAgentConfig.signing.entitlements_file,
            ASSETCATALOG_COMPILER_APPICON_NAME: "AppIcon",
            OTHER_LDFLAGS: "-framework EventKit -framework Contacts -framework ScriptingBridge"
          }
        }
      }
    }
  };

  return config;
}

fs.writeFileSync(path.join(rootDir, 'agent-mac/project.yml'), yaml.dump(generateXcodeGenConfig()));

function formatScalar(key, value) {
  if (typeof value === 'string') {
    return `${key} = "${value}"`;
  }
  if (typeof value === 'boolean') {
    return `${key} = ${value}`;
  }
  return `${key} = ${value}`;
}

function formatVarScalar(key, value) {
  if (typeof value === 'boolean') {
    return `${key} = "${value ? 'true' : 'false'}"`;
  }
  return formatScalar(key, value);
}

function formatObjectLines(obj, formatValue = formatScalar) {
  let result = '';
  for (const [key, value] of Object.entries(obj)) {
    if (value === undefined || value === null) continue;
    result += `${formatValue(key, value)}\n`;
  }
  return result;
}

function formatArrayOfTables(tablePath, items) {
  let result = '';
  for (const item of items) {
    result += `\n[[${tablePath}]]\n`;
    result += formatObjectLines(item);
  }
  return result;
}

function formatWorkerSection(config, envPrefix = '') {
  const prefix = envPrefix ? `${envPrefix}.` : '';
  let result = '';

  if (config.vars) {
    result += `\n[${prefix}vars]\n`;
    result += formatObjectLines(config.vars, formatVarScalar);
  }

  if (config.d1_databases) {
    result += formatArrayOfTables(`${prefix}d1_databases`, config.d1_databases);
  }

  if (config.r2_buckets) {
    result += formatArrayOfTables(`${prefix}r2_buckets`, config.r2_buckets);
  }

  if (config.vectorize) {
    result += formatArrayOfTables(`${prefix}vectorize`, config.vectorize);
  }

  if (config.ai) {
    result += `\n[${prefix}ai]\n`;
    result += formatObjectLines(config.ai);
  }

  if (config.durable_objects?.bindings) {
    result += formatArrayOfTables(`${prefix}durable_objects.bindings`, config.durable_objects.bindings);
  }

  if (config.migrations?.length) {
    for (const migration of config.migrations) {
      result += `\n[[${prefix}migrations]]\n`;
      result += `${formatScalar('tag', migration.tag)}\n`;
      if (migration.new_sqlite_classes?.length) {
        result += `new_sqlite_classes = [ ${migration.new_sqlite_classes.map((className) => `"${className}"`).join(', ')} ]\n`;
      }
    }
  }

  if (config.queues?.producers) {
    result += formatArrayOfTables(`${prefix}queues.producers`, config.queues.producers);
  }

  if (config.queues?.consumers) {
    result += formatArrayOfTables(`${prefix}queues.consumers`, config.queues.consumers);
  }

  if (config.triggers?.crons?.length) {
    result += `\n[${prefix}triggers]\n`;
    result += `crons = [${config.triggers.crons.map((cron) => `"${cron}"`).join(', ')}]\n`;
  }

  return result;
}

function tomlify(config) {
  let result = '';

  for (const key of ['name', 'main', 'compatibility_date']) {
    if (config[key] !== undefined) {
      result += `${formatScalar(key, config[key])}\n`;
    }
  }

  if (config.compatibility_flags?.length) {
    result += `compatibility_flags = [${config.compatibility_flags.map((flag) => `"${flag}"`).join(', ')}]\n`;
  }

  if (config.workers_dev !== undefined) {
    result += `${formatScalar('workers_dev', config.workers_dev)}\n`;
  }

  result += formatWorkerSection(config);

  if (config.env) {
    for (const [envName, envConfig] of Object.entries(config.env)) {
      result += formatWorkerSection(envConfig, `env.${envName}`);
    }
  }

  return `${result.trim()}\n`;
}

console.log('Configuration files generated successfully');
