import assert from "node:assert/strict";
import test from "node:test";
import {
  ClaudeTurnRouter,
  closureDoneMessageId,
  closureIsEmpty,
  closureNotificationOnly,
  interruptRequest,
  parseControlResponse,
  workflowRows,
  workflowRowState,
  type TurnClosure
} from "./claudeCode.js";

// ClaudeTurnRouter（常駐の claude の stdout の行と、ターン＝発話・知らせの結び付け）を、実測の行の並びで確かめる
// （docs/BACKGROUND_WORK_2026-10-21.md §3.3。claude 2.1.300、probe-uuid の U1〜U3、probe-stream の S1・S9・S6a・S13）。
// 行はルーターの判断に関わる項目だけを残したもの（並びと種類は実測のまま。mac の ClaudeTurnRouterTests と同じ）。
// `>send <uuid>` は stdin に user 行を書いた時点（uuid を付けていない probe は仮の id）、`>interrupt <id>` は停止の制御要求を書いた時点。

/* 実測の行の並び（ルーターの判断に関わる項目だけを残した。mac の ClaudeTurnRouterTests の Probe と同じ）。 */
const U1: string[] = [
  ">send aaaaaaaa-0000-4000-8000-000000000001",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"aaaaaaaa-0000-4000-8000-000000000001\",\"state\":\"queued\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"aaaaaaaa-0000-4000-8000-000000000001\",\"state\":\"started\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000001\"]}",
  "{\"type\":\"stream_event\",\"user_message_uuid\":\"aaaaaaaa-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000001\"],\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"assistant\",\"user_message_uuid\":\"aaaaaaaa-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000001\"],\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"toolu_01QwZioMM3wQMAAbpXyi4kRo\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"rate_limit_event\"}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"b0pg8yn6s\",\"task_type\":\"local_bash\",\"is_backgrounded\":true}",
  "{\"type\":\"user\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000001\"]}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"started\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"started\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"user_message_uuid\":\"aaaaaaaa-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000001\"],\"is_error\":false,\"result\":\"started\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"aaaaaaaa-0000-4000-8000-000000000001\",\"state\":\"completed\"}",
  "{\"type\":\"system\",\"subtype\":\"task_updated\",\"task_id\":\"b0pg8yn6s\",\"patch\":{\"status\":\"completed\"}}",
  "{\"type\":\"system\",\"subtype\":\"task_notification\",\"status\":\"completed\",\"task_id\":\"b0pg8yn6s\"}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"The background `\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"sleep 12;\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" echo done` command finished with\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" exit code 0.\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"The background `sleep 12; echo done` com\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"origin\":{\"kind\":\"task-notification\",\"producer\":\"session-task\",\"runId\":\"0mvgtiebl-d2ad42b7\"},\"is_error\":false,\"result\":\"The background `sleep 12; echo done` command finished with exit code 0.\"}",
  ">send aaaaaaaa-0000-4000-8000-000000000002",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"aaaaaaaa-0000-4000-8000-000000000002\",\"state\":\"queued\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"aaaaaaaa-0000-4000-8000-000000000002\",\"state\":\"started\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000002\"]}",
  "{\"type\":\"stream_event\",\"user_message_uuid\":\"aaaaaaaa-0000-4000-8000-000000000002\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000002\"],\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"7\"}}}",
  "{\"type\":\"assistant\",\"user_message_uuid\":\"aaaaaaaa-0000-4000-8000-000000000002\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000002\"],\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"7\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"user_message_uuid\":\"aaaaaaaa-0000-4000-8000-000000000002\",\"user_message_uuids\":[\"aaaaaaaa-0000-4000-8000-000000000002\"],\"is_error\":false,\"result\":\"7\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"aaaaaaaa-0000-4000-8000-000000000002\",\"state\":\"completed\"}"
];

const U2: string[] = [
  ">send bbbbbbbb-0000-4000-8000-000000000001",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"bbbbbbbb-0000-4000-8000-000000000001\",\"state\":\"queued\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"bbbbbbbb-0000-4000-8000-000000000001\",\"state\":\"started\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\",\"user_message_uuids\":[\"bbbbbbbb-0000-4000-8000-000000000001\"]}",
  "{\"type\":\"stream_event\",\"user_message_uuid\":\"bbbbbbbb-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"bbbbbbbb-0000-4000-8000-000000000001\"],\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"assistant\",\"user_message_uuid\":\"bbbbbbbb-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"bbbbbbbb-0000-4000-8000-000000000001\"],\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"toolu_01HbsptbsMSmLVoDAteWRo8r\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"rate_limit_event\"}",
  ">send bbbbbbbb-0000-4000-8000-000000000002",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"bbbbbbbb-0000-4000-8000-000000000002\",\"state\":\"queued\"}",
  "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"bnfo427p8\",\"task_type\":\"local_bash\",\"is_backgrounded\":false}",
  "{\"type\":\"system\",\"subtype\":\"task_notification\",\"status\":\"completed\",\"task_id\":\"bnfo427p8\"}",
  "{\"type\":\"user\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"bbbbbbbb-0000-4000-8000-000000000002\",\"state\":\"started\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\",\"user_message_uuids\":[\"bbbbbbbb-0000-4000-8000-000000000001\",\"bbbbbbbb-0000-4000-8000-000000000002\"]}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"first\\n\\nB\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ANANA\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"first\\n\\nBANANA\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"bbbbbbbb-0000-4000-8000-000000000002\",\"state\":\"completed\"}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"user_message_uuid\":\"bbbbbbbb-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"bbbbbbbb-0000-4000-8000-000000000001\",\"bbbbbbbb-0000-4000-8000-000000000002\"],\"is_error\":false,\"result\":\"first\\n\\nBANANA\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"bbbbbbbb-0000-4000-8000-000000000001\",\"state\":\"completed\"}"
];

const U3: string[] = [
  ">send cccccccc-0000-4000-8000-000000000001",
  ">send cccccccc-0000-4000-8000-000000000002",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"cccccccc-0000-4000-8000-000000000001\",\"state\":\"queued\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"cccccccc-0000-4000-8000-000000000001\",\"state\":\"started\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"cccccccc-0000-4000-8000-000000000002\",\"state\":\"queued\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\",\"user_message_uuids\":[\"cccccccc-0000-4000-8000-000000000001\"]}",
  "{\"type\":\"stream_event\",\"user_message_uuid\":\"cccccccc-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"cccccccc-0000-4000-8000-000000000001\"],\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"one\"}}}",
  "{\"type\":\"assistant\",\"user_message_uuid\":\"cccccccc-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"cccccccc-0000-4000-8000-000000000001\"],\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"one\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"rate_limit_event\"}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"user_message_uuid\":\"cccccccc-0000-4000-8000-000000000001\",\"user_message_uuids\":[\"cccccccc-0000-4000-8000-000000000001\"],\"is_error\":false,\"result\":\"one\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"cccccccc-0000-4000-8000-000000000001\",\"state\":\"completed\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"cccccccc-0000-4000-8000-000000000002\",\"state\":\"started\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\",\"user_message_uuids\":[\"cccccccc-0000-4000-8000-000000000002\"]}",
  "{\"type\":\"stream_event\",\"user_message_uuid\":\"cccccccc-0000-4000-8000-000000000002\",\"user_message_uuids\":[\"cccccccc-0000-4000-8000-000000000002\"],\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"two\"}}}",
  "{\"type\":\"assistant\",\"user_message_uuid\":\"cccccccc-0000-4000-8000-000000000002\",\"user_message_uuids\":[\"cccccccc-0000-4000-8000-000000000002\"],\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"user_message_uuid\":\"cccccccc-0000-4000-8000-000000000002\",\"user_message_uuids\":[\"cccccccc-0000-4000-8000-000000000002\"],\"is_error\":false,\"result\":\"two\"}",
  "{\"type\":\"command_lifecycle\",\"command_uuid\":\"cccccccc-0000-4000-8000-000000000002\",\"state\":\"completed\"}"
];

const S1: string[] = [
  ">send S1-1",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Agent\",\"id\":\"toolu_01NEYDAuv9CV68fDZ6xGGRqK\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"a57c174413ad17401\",\"task_type\":\"local_agent\",\"is_backgrounded\":true}",
  "{\"type\":\"user\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"rate_limit_event\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"assistant\",\"parent_tool_use_id\":\"toolu_01NEYDAuv9CV68fDZ6xGGRqK\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"toolu_01NLgsBJ9DMyxtTkphdRxbJJ\"}]}}",
  "{\"type\":\"system\",\"subtype\":\"task_progress\",\"task_id\":\"a57c174413ad17401\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"system\",\"subtype\":\"thinking_tokens\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\"}}}",
  "{\"type\":\"system\",\"subtype\":\"thinking_tokens\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"signature_delta\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"The s\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"leep probe sub\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"agent is running\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" in\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" the background,\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" so I don\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"'t have its output\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" yet. It was\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" launched as\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" a\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" general-purpose agent with\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" the\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" instruction to run `sle\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ep 20; echo hi\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"`\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" and report the result\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" ex\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"actly as\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" returned. I'll report what\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" it says\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" when\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" its completion not\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ification arrives.\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"The sleep probe subagent is running in t\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"The sleep probe subagent is running in the background, so I don't have its output yet. It was launched as a general-purpose agent with the instruction to run `sleep 20; echo hi` and report the result exactly as returned. I'll report what it says when its completion notification arrives.\"}",
  "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"bew97awf2\",\"task_type\":\"local_bash\",\"is_backgrounded\":false}",
  "{\"type\":\"system\",\"subtype\":\"task_notification\",\"status\":\"completed\",\"task_id\":\"bew97awf2\"}",
  "{\"type\":\"user\",\"parent_tool_use_id\":\"toolu_01NEYDAuv9CV68fDZ6xGGRqK\"}",
  "{\"type\":\"assistant\",\"parent_tool_use_id\":\"toolu_01NEYDAuv9CV68fDZ6xGGRqK\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"The command returned:\\n\\n```\\nhi\\n```\"}]}}",
  "{\"type\":\"system\",\"subtype\":\"task_updated\",\"task_id\":\"a57c174413ad17401\",\"patch\":{\"status\":\"completed\"}}",
  "{\"type\":\"system\",\"subtype\":\"task_notification\",\"status\":\"completed\",\"task_id\":\"a57c174413ad17401\"}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"The sleep probe re\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ported `\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi`. The sub\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"agent ran `sleep\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" 20; echo hi`\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" once\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" and\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" returned that\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" output.\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"The sleep probe reported `hi`. The subag\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"origin\":{\"kind\":\"task-notification\",\"producer\":\"session-task\",\"runId\":\"0mvgqsf7a-a06fabb6\"},\"is_error\":false,\"result\":\"The sleep probe reported `hi`. The subagent ran `sleep 20; echo hi` once and returned that output.\"}",
  ">send S1-2",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"It\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" reported `hi`.\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"It reported `hi`.\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"It reported `hi`.\"}"
];

const S9: string[] = [
  ">send S9-1",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"toolu_01Jj15HTgWjF9pAjhwDCKLLE\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"rate_limit_event\"}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"b1gjn7uhu\",\"task_type\":\"local_bash\",\"is_backgrounded\":true}",
  "{\"type\":\"user\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"started\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"started\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"started\"}",
  "{\"type\":\"system\",\"subtype\":\"task_updated\",\"task_id\":\"b1gjn7uhu\",\"patch\":{\"status\":\"completed\"}}",
  "{\"type\":\"system\",\"subtype\":\"task_notification\",\"status\":\"completed\",\"task_id\":\"b1gjn7uhu\"}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  ">send S9-2",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"The background command\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" finished with\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" exit code 0.\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" Its output was `done`.\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"The background command finished with exi\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"origin\":{\"kind\":\"task-notification\",\"producer\":\"session-task\",\"runId\":\"0mvgr1y1c-2a982f6d\"},\"is_error\":false,\"result\":\"The background command finished with exit code 0. Its output was `done`.\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"6\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"6\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"6\"}"
];

const S6A: string[] = [
  ">send S6a-1",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"system\",\"subtype\":\"thinking_tokens\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\"}}}",
  "{\"type\":\"system\",\"subtype\":\"thinking_tokens\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"signature_delta\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Agent\",\"id\":\"toolu_01Krdao7deuMy7VFG9tZABSm\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"ad89290d7c628b4e5\",\"task_type\":\"local_agent\",\"is_backgrounded\":true}",
  ">interrupt probe-1",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"user\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"rate_limit_event\"}",
  "{\"type\":\"system\",\"subtype\":\"task_updated\",\"task_id\":\"ad89290d7c628b4e5\",\"patch\":{\"status\":\"killed\"}}",
  "{\"type\":\"system\",\"subtype\":\"task_notification\",\"status\":\"stopped\",\"task_id\":\"ad89290d7c628b4e5\"}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"probe-1\",\"response\":{\"still_queued\":[]}}}",
  "{\"type\":\"user\",\"parent_tool_use_id\":\"toolu_01Krdao7deuMy7VFG9tZABSm\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"user\"}",
  "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true}",
  ">send S6a-2",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"alive\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"alive\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"rate_limit_event\"}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"alive\"}"
];

const S13: string[] = [
  ">send S13-1",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"toolu_01FpkDx9mJGDo2hmfjFJXvie\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"rate_limit_event\"}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"bqcgu5eyg\",\"task_type\":\"local_bash\",\"is_backgrounded\":true}",
  "{\"type\":\"user\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"id\":\"toolu_012ke7WSRZm2xnMaXE8pBeHr\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  ">interrupt probe-4",
  "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"probe-4\",\"response\":{\"still_queued\":[]}}}",
  "{\"type\":\"user\"}",
  "{\"type\":\"user\"}",
  "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true}",
  "{\"type\":\"system\",\"subtype\":\"task_updated\",\"task_id\":\"bqcgu5eyg\",\"patch\":{\"status\":\"completed\"}}",
  "{\"type\":\"system\",\"subtype\":\"task_notification\",\"status\":\"completed\",\"task_id\":\"bqcgu5eyg\"}",
  "{\"type\":\"system\",\"subtype\":\"background_tasks_changed\"}",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"system\",\"subtype\":\"thinking_tokens\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\"}}}",
  "{\"type\":\"system\",\"subtype\":\"thinking_tokens\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"signature_delta\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"The\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" background step finished (\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"`\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"sleep 19; echo\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" q`\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\", exit \"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"0). I stopped before step\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" 2: you\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" interrupted the foreground\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" `sleep 12; ech\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"o fg2`\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\", so I haven't run it\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\". I\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"'m not s\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ending \\\"\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"done\\\" because\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" step\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" 2 didn't complete\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\". Should I run the\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" foreground command\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" now,\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" or st\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"op here\"}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"?\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"The background step finished (`sleep 19;\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"origin\":{\"kind\":\"task-notification\",\"producer\":\"session-task\",\"runId\":\"0mvgr5cxx-f7894e7b\"},\"is_error\":false,\"result\":\"The background step finished (`sleep 19; echo q`, exit 0). I stopped before step 2: you interrupted the foreground `sleep 12; echo fg2`, so I haven't run it. I'm not sending \\\"done\\\" because step 2 didn't complete. Should I run the foreground command now, or stop here?\"}",
  ">send S13-2",
  "{\"type\":\"system\",\"subtype\":\"init\"}",
  "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"alive\"}}}",
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"alive\"}]}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\"}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{}}}",
  "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
  "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"alive\"}"
];

/** 知らせのターンの id を N1, N2 … と振る（テストで名指しできるように）。 */
function ids(): () => string {
  let n = 0;
  return () => `N${++n}`;
}

/** アダプター（ClaudeCodeSession）と同じ帳簿で行を流した結果。どのターンに本文が流れ、どう閉じたか。 */
interface Replay {
  router: ClaudeTurnRouter;
  /** messageId → 流れた本文 */
  texts: Map<string, string>;
  closures: TurnClosure[];
  switches: string[][];
  opened: string[];
  swallowed: number;
}

/** 発話の messageId（stdin の uuid はその小文字）。 */
const mid = (uuid: string): string => uuid.toUpperCase();

function replay(fixture: string[]): Replay {
  const r: Replay = { router: new ClaudeTurnRouter(ids()), texts: new Map(), closures: [], switches: [], opened: [], swallowed: 0 };
  /** 停止を書いたときのターン（アダプターの PendingInterrupt.targets） */
  let targets = new Set<string>();
  for (const line of fixture) {
    if (line.startsWith(">send ")) {
      const id = mid(line.slice(6));
      r.router.register(id);
      r.texts.set(id, "");
      continue;
    }
    if (line.startsWith(">interrupt")) {
      targets = new Set([...r.router.registered.map((t) => t.messageId), ...(r.router.notificationId ? [r.router.notificationId] : [])]);
      continue;
    }
    const o = JSON.parse(line) as Record<string, unknown>;
    if (o.type === "control_response") {
      const c = r.router.acknowledgeInterrupt(targets, []);
      if (!closureIsEmpty(c)) r.closures.push(c);
      continue;
    }
    const step = r.router.ingest(o);
    if (step.openedNotification !== undefined) {
      r.opened.push(step.openedNotification);
      r.texts.set(step.openedNotification, "");
    }
    if (step.switchedFrom !== undefined && r.router.current !== undefined) r.switches.push([step.switchedFrom, r.router.current]);
    if (step.swallowed) r.swallowed += 1;
    const text = ((o.event as Record<string, unknown> | undefined)?.delta as Record<string, unknown> | undefined)?.text;
    if (!step.swallowed && step.output !== undefined && ClaudeTurnRouter.isTextDelta(o) && typeof text === "string") {
      r.texts.set(step.output, (r.texts.get(step.output) ?? "") + text);
    }
    if (step.closure) r.closures.push(step.closure);
  }
  return r;
}

const closure = (messageIds: string[], notificationId?: string, interrupted = false): TurnClosure => ({
  messageIds,
  notificationId,
  interrupted,
  emitsDone: true
});

const line = (json: string): Record<string, unknown> => JSON.parse(json) as Record<string, unknown>;

/* ── uuid を返す CLI（2.1.300） ── */

test("U1: 知らせのターン（uuid の無い status・origin 付きの result）は発話に混ざらず、done は知らせのターンだけで出る", () => {
  const a = mid("aaaaaaaa-0000-4000-8000-000000000001");
  const b = mid("aaaaaaaa-0000-4000-8000-000000000002");
  const r = replay(U1);
  assert.deepEqual(r.closures, [closure([a]), closure([], "N1"), closure([b])]);
  assert.equal(closureNotificationOnly(r.closures[1]), true, "知らせのターンだけを閉じる done（origin = task-notification）");
  assert.equal(r.texts.get(a), "started");
  assert.equal(r.texts.get("N1"), "The background `sleep 12; echo done` command finished with exit code 0.");
  assert.equal(r.texts.get(b), "7");
  assert.deepEqual(r.opened, ["N1"]);
  assert.deepEqual(r.switches, []);
  assert.equal(r.router.registered.length, 0, "閉じ残しが無い");
  assert.equal(r.router.isIdle, true);
});

test("U2: 生成中に差し込んだ B は A のターンに合流し、1 つの result で両方閉じる（done は B で 1 回）", () => {
  const a = mid("bbbbbbbb-0000-4000-8000-000000000001");
  const b = mid("bbbbbbbb-0000-4000-8000-000000000002");
  const r = replay(U2);
  assert.deepEqual(r.closures, [closure([a, b])]);
  assert.equal(closureDoneMessageId(r.closures[0]), b);
  assert.deepEqual(r.switches, [[a, b]], "B が始まったところで吹き出しを区切る");
  assert.equal(r.texts.get(a), "");
  assert.equal(r.texts.get(b), "first\n\nBANANA");
  assert.equal(r.router.registered.length, 0, "B が閉じ残らない（次の発話の返事が B に入らない）");
});

test("U3: 続けて書いた 2 通は順に処理され、それぞれの result で閉じる", () => {
  const one = mid("cccccccc-0000-4000-8000-000000000001");
  const two = mid("cccccccc-0000-4000-8000-000000000002");
  const r = replay(U3);
  assert.deepEqual(r.closures, [closure([one]), closure([two])]);
  assert.equal(r.texts.get(one), "one");
  assert.equal(r.texts.get(two), "two");
  assert.deepEqual(r.switches, []);
});

/* ── uuid を返さない古い CLI（command_lifecycle を見ていない → FIFO） ── */

test("S1: サブエージェントの行と task_* は出力ではない。登録の無いときの出力は知らせのターン、登録があれば先頭の発話へ", () => {
  const r = replay(S1);
  assert.deepEqual(r.closures, [closure(["S1-1"]), closure([], "N1"), closure(["S1-2"])]);
  assert.ok((r.texts.get("S1-1") ?? "").startsWith("The sleep probe subagent is running in the background"));
  assert.equal(r.texts.get("N1"), "The sleep probe reported `hi`. The subagent ran `sleep 20; echo hi` once and returned that output.");
  assert.equal(r.texts.get("S1-2"), "It reported `hi`.");
  assert.equal(r.router.sawLifecycle, false);
});

test("S9: 知らせのターンの途中に書いた発話は、知らせの本文と result を受けず、その後のターンで返事を受ける", () => {
  const r = replay(S9);
  assert.deepEqual(r.closures, [closure(["S9-1"]), closure([], "N1"), closure(["S9-2"])]);
  assert.equal(r.texts.get("N1"), "The background command finished with exit code 0. Its output was `done`.");
  assert.equal(r.texts.get("S9-2"), "6");
});

/* ── 停止（control_request の interrupt） ── */

test("S6a: 停止の返事で発話を中断として閉じ、中断したターンの残り（status・中断の印・result）は捨てる", () => {
  const r = replay(S6A);
  assert.deepEqual(r.closures, [closure(["S6A-1"], undefined, true), closure(["S6A-2"])]);
  assert.equal(r.swallowed, 3);
  assert.deepEqual(r.opened, [], "中断の残りで知らせのターンを開かない");
  assert.equal(r.texts.get("S6A-2"), "alive");
});

test("S13: 中断の result は捨て、残ったバックグラウンドのシェルが終わったときの知らせのターンは普通に出す", () => {
  const r = replay(S13);
  assert.deepEqual(r.closures, [closure(["S13-1"], undefined, true), closure([], "N1"), closure(["S13-2"])]);
  assert.equal(r.swallowed, 3);
  assert.ok((r.texts.get("N1") ?? "").startsWith("The background step finished (`sleep 19; echo q`, exit 0)."));
  assert.equal(r.texts.get("S13-2"), "alive");
});

/* ── 規則ごと ── */

test("知らせのターンに発話が合流したら、その発話へ切り替え、result で両方閉じる（done は発話）", () => {
  const router = new ClaudeTurnRouter(ids());
  const opened = router.ingest(line('{"type":"system","subtype":"status","status":"requesting"}'));
  assert.equal(opened.openedNotification, "N1");
  router.register("X1");
  const started = router.ingest(line('{"type":"command_lifecycle","command_uuid":"x1","state":"started"}'));
  assert.equal(started.switchedFrom, "N1");
  assert.equal(router.current, "X1");
  const done = router.ingest(line('{"type":"result","subtype":"success","user_message_uuids":["x1"],"origin":{"kind":"task-notification"}}'));
  assert.deepEqual(done.closure, closure(["X1"], "N1"));
  assert.equal(closureDoneMessageId(done.closure!), "X1");
  assert.equal(closureNotificationOnly(done.closure!), false);
});

test("command_lifecycle completed が始まっていない発話に来たら閉じる。ほかのターンが出力している間は done を出さない", () => {
  const router = new ClaudeTurnRouter();
  router.register("A");
  router.register("B");
  router.ingest(line('{"type":"command_lifecycle","command_uuid":"a","state":"started"}'));
  const quiet = router.ingest(line('{"type":"command_lifecycle","command_uuid":"b","state":"completed"}'));
  assert.deepEqual(quiet.closure?.messageIds, ["B"]);
  assert.equal(quiet.closure?.emitsDone, false);
  // 始まった発話の completed では閉じない（result で閉じる）。
  assert.equal(router.ingest(line('{"type":"command_lifecycle","command_uuid":"a","state":"completed"}')).closure, undefined);
  assert.deepEqual(router.registered.map((t) => t.messageId), ["A"]);
});

test("cancel_queued で取り消された発話（command_lifecycle cancelled）は中断として閉じる", () => {
  const router = new ClaudeTurnRouter();
  router.register("A");
  const step = router.ingest(line('{"type":"command_lifecycle","command_uuid":"a","state":"cancelled"}'));
  assert.deepEqual(step.closure, closure(["A"], undefined, true));
});

test("停止の返事は止めると決めたときのターンだけを閉じ、後から送った発話とまだ走る発話（still_queued）は残す", () => {
  const router = new ClaudeTurnRouter();
  router.register("A");
  router.register("Q");
  router.ingest(line('{"type":"command_lifecycle","command_uuid":"a","state":"started"}'));
  const targets = new Set(["A", "Q"]);
  router.register("LATE");
  const c = router.acknowledgeInterrupt(targets, ["q"]);
  assert.deepEqual(c, closure(["A"], undefined, true));
  assert.deepEqual(router.registered.map((t) => t.messageId), ["Q", "LATE"]);
  assert.equal(router.draining, true);
  // 中断したターンの result は捨て、生き延びた Q が始まれば普通に流す。
  assert.equal(router.ingest(line('{"type":"result","subtype":"error_during_execution","user_message_uuids":["a"]}')).swallowed, true);
  router.ingest(line('{"type":"command_lifecycle","command_uuid":"q","state":"started"}'));
  const delta = router.ingest(line('{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"q"}}}'));
  assert.equal(delta.output, "Q");
});

test("停止の返事の前に止めるターンが result で終わっていたら、返事では何も閉じず、残りも捨てない", () => {
  const router = new ClaudeTurnRouter();
  router.register("A");
  router.ingest(line('{"type":"command_lifecycle","command_uuid":"a","state":"started"}'));
  assert.deepEqual(router.ingest(line('{"type":"result","subtype":"success","user_message_uuids":["a"]}')).closure, closure(["A"]));
  const c = router.acknowledgeInterrupt(new Set(["A"]), []);
  assert.equal(closureIsEmpty(c), true);
  assert.equal(router.draining, false);
  assert.ok(router.ingest(line('{"type":"system","subtype":"status","status":"requesting"}')).openedNotification);
});

test("閉じた発話の uuid の行は捨て、CLI の内部の uuid（知らないもの）の行は知らせのターンとして開いて閉じる", () => {
  const router = new ClaudeTurnRouter();
  router.register("A");
  router.ingest(line('{"type":"command_lifecycle","command_uuid":"a","state":"started"}'));
  router.ingest(line('{"type":"result","subtype":"success","user_message_uuids":["a"]}'));
  assert.equal(router.ingest(line('{"type":"system","subtype":"status","status":"requesting","user_message_uuids":["a"]}')).swallowed, true);
  assert.equal(router.ingest(line('{"type":"result","subtype":"success","user_message_uuids":["a"]}')).swallowed, true);
  const internal = router.ingest(line('{"type":"system","subtype":"status","status":"requesting","user_message_uuids":["cron-1"]}'));
  assert.ok(internal.openedNotification);
  const done = router.ingest(line('{"type":"result","subtype":"success","user_message_uuids":["cron-1"]}'));
  assert.equal(closureNotificationOnly(done.closure!), true);
});

test("サブエージェントの行・task_*・status: null・init・hook の行は出力ではない（知らせのターンを開かない）", () => {
  const router = new ClaudeTurnRouter();
  for (const json of [
    '{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"text","text":"sub"}]}}',
    '{"type":"user","parent_tool_use_id":"toolu_1"}',
    '{"type":"system","subtype":"task_started","task_id":"t1","task_type":"local_agent"}',
    '{"type":"system","subtype":"background_tasks_changed","tasks":[]}',
    '{"type":"system","subtype":"status","status":null}',
    '{"type":"system","subtype":"init"}',
    '{"type":"system","subtype":"hook_started"}',
    '{"type":"rate_limit_event"}'
  ]) {
    assert.deepEqual(router.ingest(line(json)), { swallowed: false, isResult: false }, json);
  }
  assert.equal(router.isIdle, true);
});

test("本文の差分を見たかは CLI のターンごと（見なかったターンは result の本文を本文にする）", () => {
  const router = new ClaudeTurnRouter();
  router.register("A");
  router.ingest(line('{"type":"command_lifecycle","command_uuid":"a","state":"started"}'));
  router.ingest(line('{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}}'));
  assert.equal(router.sawTextDelta, true);
  router.ingest(line('{"type":"result","subtype":"success","user_message_uuids":["a"]}'));
  assert.equal(router.sawTextDelta, false, "次のターンは数え直す");
});

test("古い CLI で書けなかった発話を外すと、次の出力は残りの先頭へ", () => {
  const router = new ClaudeTurnRouter();
  router.register("A");
  router.register("B");
  router.unregister("A");
  assert.equal(router.ingest(line('{"type":"system","subtype":"status","status":"requesting"}')).output, "B");
  // JSON でない行も同じ宛先へ。中断の残りの間は捨てる。
  assert.equal(router.routeRawText().output, "B");
});

test("停止の制御要求と、その返事（実測 S6a の形。request_id は response の中）", () => {
  assert.deepEqual(interruptRequest("r-1"), { type: "control_request", request_id: "r-1", request: { subtype: "interrupt", cancel_queued: true } });
  assert.deepEqual(parseControlResponse('{"type":"control_response","response":{"subtype":"success","request_id":"probe-1","response":{"still_queued":["a"]}}}'), {
    requestId: "probe-1",
    success: true,
    error: undefined,
    stillQueued: ["a"]
  });
  const refused = parseControlResponse('{"type":"control_response","response":{"subtype":"error","request_id":"probe-2","error":"nothing to interrupt"}}');
  assert.equal(refused?.success, false);
  assert.equal(refused?.error, "nothing to interrupt");
  assert.equal(parseControlResponse('{"type":"assistant","message":{"content":[{"type":"text","text":"the control_response type"}]}}'), undefined);
  assert.equal(parseControlResponse('{"type":"control_request","request_id":"x","request":{"subtype":"can_use_tool"}}'), undefined);
});

test("dynamic workflow の行: phase の見出しは行にせず、state をそろえ、失敗の理由と開始時刻を入れる", () => {
  assert.deepEqual(
    ["start", "progress", "running", "done", "completed", "error", "failed", "killed", "stopped", "cancelled", "queued"].map((s) => workflowRowState(s)),
    ["running", "running", "running", "done", "done", "failed", "failed", "stopped", "stopped", "stopped", "queued"]
  );
  assert.equal(workflowRowState(undefined), undefined);
  const rows = workflowRows([
    { type: "workflow_phase", index: 1, title: "Plan" },
    { type: "workflow_agent", index: 1, label: "planner", phaseIndex: 1, phaseTitle: "Plan", state: "progress", startedAt: 1760000000000.7, model: null },
    { type: "workflow_agent", index: 2, label: "checker", state: "error", error: "boom" },
    { type: "workflow_log", index: 3, text: "x" }
  ]);
  assert.deepEqual(rows, [
    { index: 1, label: "planner", phaseIndex: 1, phaseTitle: "Plan", state: "running", startedAtMs: 1760000000000 },
    { index: 2, label: "checker", state: "failed", resultPreview: "boom" }
  ]);
});
