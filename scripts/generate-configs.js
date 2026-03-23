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
    queues: workerName === 'sky-ai' ? {
      producers: [{
        binding: "EMBEDDING_QUEUE",
        queue: sharedConfig.prod?.queues?.embedding_queue || "sky-ai-embeddings-dev"
      }]
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
      } : undefined
    }
  };

  return config;
}

// Generate main worker config
const mainWorkerConfig = generateWranglerConfig('sky-ai', 'src/worker.ts');
fs.writeFileSync(path.join(rootDir, 'wrangler.toml'), tomlify(mainWorkerConfig));

// Generate API worker config
const apiWorkerConfig = generateWranglerConfig('sky-ai-api', 'workers/api/src/worker.ts', {
  WORKERS_AI_EMBEDDING_MODEL: "@cf/baai/bge-base-en-v1.5",
  WORKERS_AI_CHAT_MODEL: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
  VECTOR_DIMENSIONS: "1536"
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
    targets: {
      BlawbyAgent: {
        type: "application",
        platform: "macOS",
        sources: [
          { path: "Sources/BlawbyAgent" }
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
        dependencies: [
          { package: "GRDB", product: "GRDB" },
          { package: "Sparkle", product: "Sparkle" }
        ],
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

// Helper function to convert object to TOML
function tomlify(obj, indent = '') {
  let result = '';
  
  for (const [key, value] of Object.entries(obj)) {
    if (value === undefined || value === null) continue;
    
    if (typeof value === 'object' && !Array.isArray(value)) {
      if (key === 'env') {
        result += '\n[env]\n';
        for (const [envKey, envValue] of Object.entries(value)) {
          result += tomlify({ [envKey]: envValue }, '  ');
        }
      } else if (Array.isArray(value)) {
        for (const item of value) {
          if (typeof item === 'object') {
            result += `\n[[${key}]]\n`;
            result += tomlify(item, '  ');
          }
        }
      } else {
        result += `\n[${key}]\n`;
        result += tomlify(value, '  ');
      }
    } else if (Array.isArray(value)) {
      for (const item of value) {
        if (typeof item === 'object') {
          result += `\n[[${key}]]\n`;
          result += tomlify(item, indent);
        }
      }
    } else if (typeof value === 'string') {
      result += `${indent}${key} = "${value}"\n`;
    } else if (typeof value === 'boolean') {
      result += `${indent}${key} = ${value}\n`;
    } else {
      result += `${indent}${key} = ${value}\n`;
    }
  }
  
  return result;
}

console.log('Configuration files generated successfully');
