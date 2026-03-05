export type CitationRecord = {
  messageId: string;
  date: string | null;
  from: string;
  subject: string;
  score: number;
};

export type CitationQueryResult = {
  intent: string;
  answer: string;
  citations: CitationRecord[];
  citationStatus: 'sufficient' | 'insufficient';
  searched: Record<string, unknown>;
};

export function enforceCitationContract(
  query: string,
  result: CitationQueryResult
): CitationQueryResult {
  const searched: Record<string, unknown> = {
    ...(result.searched || {}),
    query,
    intent: result.intent,
    validator: 'citation_contract_v1'
  };

  if (result.citations.length > 0) {
    return {
      ...result,
      citationStatus: 'sufficient',
      searched
    };
  }

  return {
    ...result,
    answer:
      `Insufficient sources for a factual answer (${result.intent}). ` +
      'I did not find citation-backed evidence for this request.',
    citationStatus: 'insufficient',
    searched
  };
}
