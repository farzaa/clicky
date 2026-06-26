import { registerAuthStatusAccessAssertions } from "./authStatusAccessAssertions.mjs";
import { registerMagicLinkConfirmBridgeAssertions } from "./magicLinkConfirmBridgeAssertions.mjs";
import { registerMagicLinkStartAssertions } from "./magicLinkStartAssertions.mjs";

export function registerAuthSessionAssertions(dependencies) {
  registerAuthStatusAccessAssertions(dependencies);
  registerMagicLinkStartAssertions(dependencies);
  registerMagicLinkConfirmBridgeAssertions(dependencies);
}
