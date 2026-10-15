import { LaunchProps } from "@raycast/api";
import { Editor } from "./editor";

export default function Command(props: LaunchProps<{ arguments: { text?: string } }>) {
  return <Editor action="rewrite" {...props} />;
}
