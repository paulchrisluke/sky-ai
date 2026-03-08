import { Agent } from 'agents';

type BlawbyEnv = Cloudflare.Env & {
  SKY_DB: D1Database;
  OPENAI_API_KEY: string;
  CF_AIG_AUTH_TOKEN?: string;
  AIG_ACCOUNT_ID: string;
  AIG_GATEWAY_ID: string;
};

export type BlawbyAgentState = {
  immediateContext: string;
  shortTermMemory: string;
  longTermMemory: string;
  knowledgeProfile: string;
};

type GatewayChatResponse = {
  choices?: Array<{
    message?: {
      content?: string;
    };
  }>;
};

export class BlawbyAgent extends Agent<BlawbyEnv, BlawbyAgentState> {
  initialState: BlawbyAgentState = {
    immediateContext: '',
    shortTermMemory: '',
    longTermMemory: '',
    knowledgeProfile: ''
  };

  async skillImmediateContext(): Promise<void> {
    console.log('[blawby] skill_immediate_context started');

    const calendarResult = await this.env.SKY_DB
      .prepare(
        `SELECT start_at, title
         FROM calendar_events
         WHERE datetime(start_at) >= datetime(CURRENT_TIMESTAMP)
           AND datetime(start_at) < datetime(CURRENT_TIMESTAMP, '+4 hours')
         ORDER BY datetime(start_at) ASC
         LIMIT 10`
      )
      .all<{ start_at: string; title: string | null }>();

    const urgentEntityResult = await this.env.SKY_DB
      .prepare(
        `SELECT counterparty_name, entity_type, action_description
         FROM email_entities
         WHERE action_required = 1
           AND datetime(created_at) >= datetime(CURRENT_TIMESTAMP, '-2 hours')
         ORDER BY datetime(created_at) DESC
         LIMIT 10`
      )
      .all<{ counterparty_name: string | null; entity_type: string; action_description: string | null }>();

    const calendarRows = calendarResult.results || [];
    const urgentRows = urgentEntityResult.results || [];

    const calendarLines = calendarRows.map((event) => `[${event.start_at}] ${event.title || ''}`);
    const urgentLines = urgentRows.map((entity) => `${entity.counterparty_name || ''} | ${entity.entity_type} | ${entity.action_description || ''}`);

    const formattedString = [
      'Immediate Context',
      'Calendar (next 4h):',
      ...calendarLines,
      'Urgent Entities (last 2h):',
      ...urgentLines
    ].join('\n');

    this.setState({
      ...this.state,
      immediateContext: formattedString
    });

    console.log(`[blawby] immediate_context updated: ${calendarRows.length} calendar events, ${urgentRows.length} urgent entities`);
  }

  async skillShortTermMemory(): Promise<void> {
    console.log('[blawby] skill_short_term_memory started');

    const entitiesResult = await this.env.SKY_DB
      .prepare(
        `SELECT *
         FROM email_entities
         WHERE datetime(created_at) >= datetime(CURRENT_TIMESTAMP, '-48 hours')
         ORDER BY datetime(created_at) DESC
         LIMIT 50`
      )
      .all<Record<string, unknown>>();

    const calendarResult = await this.env.SKY_DB
      .prepare(
        `SELECT id, title, start_at, end_at, location, calendar_name
         FROM calendar_events
         WHERE datetime(start_at) >= datetime(CURRENT_TIMESTAMP)
           AND datetime(start_at) < datetime(CURRENT_TIMESTAMP, '+48 hours')
         ORDER BY datetime(start_at) ASC
         LIMIT 20`
      )
      .all<{
        id: string;
        title: string | null;
        start_at: string;
        end_at: string;
        location: string | null;
        calendar_name: string | null;
      }>();

    const entityRows = entitiesResult.results || [];
    const calendarRows = calendarResult.results || [];

    const financialItems = entityRows
      .filter((row) => {
        const direction = String(row.direction || '').toLowerCase();
        const type = String(row.entity_type || '').toLowerCase();
        return direction === 'ar' || direction === 'ap' || type.includes('invoice') || type.includes('payment') || type.includes('bill');
      })
      .map((row) => `${String(row.created_at || '')} | ${String(row.counterparty_name || '')} | ${String(row.entity_type || '')} | ${String(row.action_description || '')}`);

    const correspondenceItems = entityRows
      .filter((row) => {
        const direction = String(row.direction || '').toLowerCase();
        const type = String(row.entity_type || '').toLowerCase();
        return !(direction === 'ar' || direction === 'ap' || type.includes('invoice') || type.includes('payment') || type.includes('bill'));
      })
      .map((row) => `${String(row.created_at || '')} | ${String(row.counterparty_name || '')} | ${String(row.entity_type || '')} | ${String(row.action_description || '')}`);

    const calendarItems = calendarRows
      .map((event) => `${event.start_at} | ${event.title || ''} | ${event.location || ''} | ${event.calendar_name || ''}`);

    const combinedContext = [
      'Financial Items:',
      ...financialItems,
      'Correspondence Items:',
      ...correspondenceItems,
      'Calendar Items:',
      ...calendarItems
    ].join('\n');

    const summary = await this.generateGatewaySummary(
      'You are Blawby, an AI chief-of-staff. Summarize the user context from the last 48 hours into 3-5 concise bullet points usable as working memory.',
      combinedContext,
      400
    );

    this.setState({
      ...this.state,
      shortTermMemory: summary
    });
  }

  async skillLongTermMemory(): Promise<void> {
    console.log('[blawby] skill_long_term_memory started');

    const counterpartyResult = await this.env.SKY_DB
      .prepare(
        `SELECT counterparty_name,
                COUNT(*) AS appearances,
                GROUP_CONCAT(DISTINCT entity_type) AS types_seen,
                GROUP_CONCAT(DISTINCT direction) AS directions,
                MAX(created_at) AS most_recent_date
         FROM email_entities
         GROUP BY counterparty_name
         ORDER BY appearances DESC
         LIMIT 30`
      )
      .all<{
        counterparty_name: string | null;
        appearances: number;
        types_seen: string | null;
        directions: string | null;
        most_recent_date: string | null;
      }>();

    const meetingResult = await this.env.SKY_DB
      .prepare(
        `SELECT title,
                COUNT(*) AS occurrences,
                MAX(start_at) AS most_recent_date
         FROM calendar_events
         GROUP BY title
         ORDER BY occurrences DESC
         LIMIT 20`
      )
      .all<{
        title: string | null;
        occurrences: number;
        most_recent_date: string | null;
      }>();

    const counterparties = (counterpartyResult.results || [])
      .map((row) => `${row.counterparty_name || ''} | appearances: ${row.appearances} | types: ${row.types_seen || ''} | directions: ${row.directions || ''} | most recent: ${row.most_recent_date || ''}`);

    const meetings = (meetingResult.results || [])
      .map((row) => `${row.title || ''} | occurrences: ${row.occurrences} | most recent: ${row.most_recent_date || ''}`);

    const context = [
      'Counterparty Patterns:',
      ...counterparties,
      'Recurring Calendar Commitments:',
      ...meetings
    ].join('\n');

    const summary = await this.generateGatewaySummary(
      'Identify recurring relationships and what they represent, recurring calendar commitments, and patterns worth remembering such as regular payments, standing meetings, and frequent contacts.',
      context,
      400
    );

    this.setState({
      ...this.state,
      longTermMemory: summary
    });
  }

  async skillKnowledgeProfile(): Promise<void> {
    console.log('[blawby] skill_knowledge_profile started');

    const context = [
      'Immediate Context:',
      this.state.immediateContext,
      'Short-Term Memory:',
      this.state.shortTermMemory,
      'Long-Term Memory:',
      this.state.longTermMemory
    ].join('\n');

    const profile = await this.generateGatewaySummary(
      'Synthesize a concise system-prompt addendum describing who Skyler is, what businesses he runs, who his key relationships are, and what his current priorities appear to be.',
      context,
      600
    );

    this.setState({
      ...this.state,
      knowledgeProfile: profile
    });
  }

  getContext(): string {
    return [
      '## Immediate Context',
      this.state.immediateContext,
      '## Short-Term Memory',
      this.state.shortTermMemory,
      '## Long-Term Memory',
      this.state.longTermMemory,
      '## Knowledge Profile',
      this.state.knowledgeProfile
    ].join('\n\n');
  }

  async onStart(): Promise<void> {
    const existing = await this.getSchedules();
    const names = existing.map((s: { callback: string }) => s.callback);

    if (!names.includes('skillImmediateContext')) {
      await this.schedule('*/15 * * * *', 'skillImmediateContext', {});
    }
    if (!names.includes('skillShortTermMemory')) {
      await this.schedule('0 * * * *', 'skillShortTermMemory', {});
    }
    if (!names.includes('skillLongTermMemory')) {
      await this.schedule('0 3 * * *', 'skillLongTermMemory', {});
    }
    if (!names.includes('skillKnowledgeProfile')) {
      await this.schedule('0 4 * * 0', 'skillKnowledgeProfile', {});
    }
  }

  private async generateGatewaySummary(systemPrompt: string, userContent: string, maxTokens: number): Promise<string> {
    const gatewayUrl = `https://gateway.ai.cloudflare.com/v1/${this.env.AIG_ACCOUNT_ID}/${this.env.AIG_GATEWAY_ID}/openai/chat/completions`;

    const headers: Record<string, string> = {
      'content-type': 'application/json',
      authorization: `Bearer ${this.env.OPENAI_API_KEY}`
    };
    if (this.env.CF_AIG_AUTH_TOKEN) {
      headers['cf-aig-authorization'] = `Bearer ${this.env.CF_AIG_AUTH_TOKEN}`;
    }

    const response = await fetch(gatewayUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userContent }
        ],
        max_tokens: maxTokens
      })
    });

    if (!response.ok) {
      throw new Error(await response.text());
    }

    const payload = await response.json<GatewayChatResponse>();
    const summary = payload.choices?.[0]?.message?.content;
    if (!summary) {
      throw new Error('Missing OpenAI response content');
    }
    return summary;
  }
}
