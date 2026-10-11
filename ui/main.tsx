import { render } from "solid-js/web";
import { Window } from "../../solid-qml-native/src/solid-qml/runtime";
import { WhatsApp } from "./app/WhatsApp";

declare const app: { settingsJson: string };

function App() {
  return (
    <Window title="WhatsApp" width={1240} height={820} visible>
      <WhatsApp />
    </Window>
  );
}

render(() => <App />, document.getElementById("root")!);
