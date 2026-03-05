INSERT INTO agents (
  id, name, purpose, business_context, priority_level, owner_goals_json, tone, created_at, updated_at
) VALUES (
  'agent_001',
  'BoostedSafe',
  'Customer support and operations for BoostedSafe consumer product business',
  'Consumer product company selling personal safes. Respond to customers within 24hrs. Flag refunds and shipping issues immediately.',
  'high',
  '["respond to customers","flag refund requests","track shipping issues","identify leads"]',
  'friendly',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);
