interface Env {
  OPENAI_API_KEY: string;
  EMAIL_HASH_SECRET?: string;
  RESEND_API_KEY?: string;
  MAGIC_LINK_FROM?: string;
  STRIPE_SECRET_KEY?: string;
  STRIPE_PRICE_ID?: string;
  STRIPE_WEBHOOK_SECRET?: string;
  DEV_RETURN_MAGIC_LINK?: string;
}
