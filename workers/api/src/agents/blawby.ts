import { Agent } from 'agents';

export type BlawbyAgentState = {
  immediateContext: string;
  shortTermMemory: string;
  longTermMemory: string;
  knowledgeProfile: string;
};

export class BlawbyAgent extends Agent<Cloudflare.Env, BlawbyAgentState> {
  initialState: BlawbyAgentState = {
    immediateContext: '',
    shortTermMemory: '',
    longTermMemory: '',
    knowledgeProfile: ''
  };

  async skillImmediateContext(): Promise<void> {
    console.log('[blawby] skill_immediate_context started');
    this.setState({
      ...this.state,
      immediateContext: 'placeholder: immediate context built'
    });
  }

  async skillShortTermMemory(): Promise<void> {
    console.log('[blawby] skill_short_term_memory started');
    this.setState({
      ...this.state,
      shortTermMemory: 'placeholder: short-term memory built'
    });
  }

  async skillLongTermMemory(): Promise<void> {
    console.log('[blawby] skill_long_term_memory started');
    this.setState({
      ...this.state,
      longTermMemory: 'placeholder: long-term memory built'
    });
  }

  async skillKnowledgeProfile(): Promise<void> {
    console.log('[blawby] skill_knowledge_profile started');
    this.setState({
      ...this.state,
      knowledgeProfile: 'placeholder: knowledge profile built'
    });
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
}
