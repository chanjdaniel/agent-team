// prod-mongo's refusal: the error a tool throws when it refuses or fails, whose message is the one
// line its answer gives (after `<tool>: failed: `), whole: any child's or the driver's text in it
// was passed through scrubbed (children.mjs) when it was built.
export class Refusal extends Error {}
