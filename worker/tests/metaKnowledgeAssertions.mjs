import path from "node:path";
import { assertMetaKnowledgeCorpus } from "./knowledgeAssertions.mjs";

export function registerMetaKnowledgeAssertions({ test, workerRoot }) {
  test("Meta knowledge files are parseable and source-honest", () => {
    const knowledgeDir = path.join(workerRoot, "knowledge");
    assertMetaKnowledgeCorpus(knowledgeDir);
  });
}
