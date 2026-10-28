import { createClient } from 'jsr:@supabase/supabase-js@2';
const cors = { 'Access-Control-Allow-Origin':'*', 'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'apikey, authorization, content-type, x-client-info', 'Content-Type':'application/json' };
const reply=(status:number,obj:unknown)=>new Response(JSON.stringify(obj),{status,headers:cors});
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 if(req.method!=='POST')return reply(405,{ok:false,message:'Method not allowed'});
 try{
  const {pin}=await req.json();
  if(typeof pin!=='string'||!(/^[A-HJ-NP-Z2-9]{12}$/.test(pin)))return reply(400,{ok:false,message:'12자리 PIN을 확인해 주세요.'});
  const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
  const {data,error}=await db.rpc('verify_gift_pin_server',{p_pin:pin});
  if(error){console.error('verify DB failure',error);return reply(500,{ok:false,message:'PIN 확인 서버 오류'});}
  return reply(data?.ok?200:403,data);
 }catch{return reply(400,{ok:false,message:'PIN 입력값을 확인해 주세요.'});}
});
