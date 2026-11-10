// A counter whose Model names the directory its dev server runs in, so a test reading the Model
// through Foldkit's DevTools MCP server can tell one copy of the app from another.
import { Schema } from 'effect'
import { Runtime, type Update } from 'foldkit'
import { type Document, type HtmlBuilder } from 'foldkit/html'
import { defineMessageUnion } from 'foldkit/message'

const Model = Schema.Struct({ app: Schema.String, count: Schema.Number })
type Model = typeof Model.Type

const Message = defineMessageUnion({ ClickedIncrement: {} })
type Message = typeof Message.Type

const update = (model: Model, message: Message) =>
  Message.match<Update.Return<Model, Message>>(message, {
    ClickedIncrement: () => ({ model: { ...model, count: model.count + 1 } }),
  })

const init: Runtime.ApplicationInit<Model, Message> = () => ({
  model: { app: import.meta.env.VITE_FIXTURE_APP ?? 'unnamed', count: 0 },
})

const view = (model: Model, h: HtmlBuilder<Message>): Document => ({
  title: `${model.app}: ${model.count}`,
  body: h.button([h.OnClick(Message.ClickedIncrement())], [`${model.count}`]),
})

Runtime.run(
  Runtime.makeApplication({
    Model,
    init,
    update,
    view,
    container: document.getElementById('root'),
    devTools: { Message },
  }),
)
