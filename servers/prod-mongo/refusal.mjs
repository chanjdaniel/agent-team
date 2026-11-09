// prod-mongo's refusal: the error a tool throws when it refuses or fails, whose message is the one
// line its answer gives (after `<tool>: failed: `).
export class Refusal extends Error {}
