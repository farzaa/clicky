import type { AuthenticatedUser, EntitlementStatus } from "./authSessionStore";

export function effectiveEntitlementStatus(user: AuthenticatedUser): EntitlementStatus {
  if (user.entitlementStatus === "blocked") {
    return "blocked";
  }

  if (user.subscriptionStatus !== null) {
    if (
      user.subscriptionStatus === "canceled"
      && user.subscriptionCurrentPeriodEnd !== null
      && user.subscriptionCurrentPeriodEnd > Math.floor(Date.now() / 1000)
    ) {
      return "active";
    }
    return entitlementStatusFromStripeSubscriptionStatus(user.subscriptionStatus);
  }

  if (user.entitlementStatus === "trial") {
    return "trial";
  }

  return user.entitlementStatus === "active" ? "active" : user.entitlementStatus;
}

export function entitlementStatusFromStripeSubscriptionStatus(stripeStatus: string): EntitlementStatus {
  switch (stripeStatus) {
    case "active":
      return "active";
    case "trialing":
      return "trial";
    case "canceled":
    case "past_due":
    case "unpaid":
    case "incomplete":
    case "incomplete_expired":
    case "paused":
      return "canceled";
    default:
      return "none";
  }
}
