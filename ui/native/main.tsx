import { render } from "solid-js/web";
import { Window } from "../../../solid-qml-native/src/solid-qml/runtime";
import { Native } from "./Native";

function App() {
  return (
    <Window title="QWhats" width={1180} height={800} visible>
      <Native />
    </Window>
  );
}

render(() => <App />, document.getElementById("root")!);
