import { createClient } from "npm:@supabase/supabase-js@2";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "apikey, authorization, content-type, x-client-info",
  "Content-Type": "application/json",
};
const reply = (status: number, obj: unknown) =>
  new Response(JSON.stringify(obj), { status, headers: cors });
Deno.serve(async (req) => {
  if (req.method === "OPTIONS")
    return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST")
    return reply(405, { ok: false, message: "Method not allowed" });
  try {
    const { pin, request_id, winner_name, items } = await req.json();
    if (typeof pin !== "string" || !/^[A-HJ-NP-Z2-9]{12}$/.test(pin))
      return reply(400, {
        ok: false,
        message: "PIN 형식이 올바르지 않습니다.",
      });
    if (
      typeof request_id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        request_id,
      )
    )
      return reply(400, { ok: false, message: "요청 ID가 올바르지 않습니다." });
    if (
      typeof winner_name !== "string" ||
      winner_name.trim().length < 1 ||
      winner_name.length > 60 ||
      !Array.isArray(items) ||
      items.length < 1 ||
      items.length > 30
    )
      return reply(400, {
        ok: false,
        message: "수상자 또는 상품 정보를 확인해 주세요.",
      });
    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } },
    );
    const { data, error } = await db.rpc("confirm_gift_pin_server", {
      p_pin: pin,
      p_request_id: request_id,
      p_winner_name: winner_name,
      p_items: items,
    });
    if (error) {
      console.error("confirm DB error", error.code, error.message);
      return reply(409, {
        ok: false,
        message:
          "선택 확정에 실패했습니다. PIN 사용 여부와 시상 한도를 확인하고 운영진에게 문의해 주세요.",
      });
    }
    return reply(200, data);
  } catch {
    return reply(400, { ok: false, message: "요청 본문을 확인해 주세요." });
  }
});
