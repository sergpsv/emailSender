CREATE OR REPLACE PACKAGE EMAILSENDER
authid current_user

  IS
-- Рассылка отчетов по корреспондентам
--
-- Author = sparshukov   
--            16/11/2004  Создание
--            20/07/2006  добавлена возможность использовать вложения
--            19/04/2008  Вложения можно архивировать
--                        Можно передавать списки файлов-вложений
--            24/06/2008  переход на сервер с авторизацией
--                        исправление мелкого база с оформлением партиций письма
--                        отказ от таблиц EMAILBODY      
--            11/04/2012  в функцию SendEmailWithAttach добавил обработку паролей
--            10/05/2012  в функцию push_header добавлена обработка спецификации Reply-to
-- ---------  ----------  ------------------------------------------
   g_sender    constant varchar2(50)     := '<autoreport@megafon.ru>';
   g_mailhost  constant VARCHAR2(50)     := 'kvk-smtp.megafon.ru'; -- smtpr.lan.megafonkavkaz.ru -- kvk-smtp.megafon.ru  
--   g_mailhost  constant VARCHAR2(50)     := 'proxyr1.lan.megafonkavkaz.ru';
   g_mail_conn          utl_smtp.connection;
   g_message            varchar2(4000)   := NULL;
--------------------------------------------------------------------------------
   g_IsOpen                 number       default 0;
   g_mailBoundary  constant varchar2(50) := 'mailpartPsv3';
--------------------------------------------------------------------------------
procedure SendTo       (p_recipient IN varchar2,p_subject IN varchar2, p_body in varchar2);
procedure SendToPsv    (p_subject IN varchar2,p_body in varchar2);
function  getMsisdnByEmail(p_recip in varchar2) return varchar2;

--------------------------------------------------------------------------------
-- способ: отправляется письмом два CLOB один - тело и один вложение
FUNCTION SendEmailWithAttach(
   p_recipient   IN TStringList,
   p_subject     IN varchar2,
   p_body        in clob)
 RETURN number;

--------------------------------------------------------------------------------
FUNCTION SendEmailWithAttach(
   p_recipient   IN varchar2,
   p_subject     IN varchar2,
   p_body        in clob,
   p_attach_name in varchar2,
   p_attach      in clob)
 RETURN number;
 
--------------------------------------------------------------------------------
 FUNCTION SendEmailWithAttach(
   recpList      IN TStringList,
   p_subject     IN varchar2,
   p_body        in clob ,
   p_attach_name in varchar2,
   p_attach      in clob)
 RETURN number;

--------------------------------------------------------------------------------
-- 4й способ: отправляется письмом список вложений с возможностью архивации
FUNCTION SendEmailWithAttach(
   recpList         IN  TStringList,
   p_subject        IN  varchar2,
   p_body           in  clob ,
   p_attachNameList in  TStringList,
   p_attachList     in  TClobList,
   p_isArch         in  boolean    default false,
   p_archPass       in  varchar2   default null)
 RETURN number;

--------------------------------------------------------------------------------
  FUNCTION SendEmailWithAttach(
   recpList         IN  TStringList,
   p_subject        IN  varchar2,
   p_body           in  clob ,
   p_attachNameList in  TStringList,
   p_attachList     in  TBlobList,
   p_isArch         in  boolean    default false,
   p_archPass       in  varchar2   default null)
 RETURN number;

--------------------------------------------------------------------------------
FUNCTION SendEmailWithAttach(
   recpList         IN  TStringList,
   p_subject        IN  varchar2,
   p_body           in  clob ,
   p_rl             in  TRItemList,
   p_isArch         in  boolean    default false)
 RETURN number;

END; -- Package spec
/
CREATE OR REPLACE PACKAGE BODY EMAILSENDER
IS

  badEmail exception;
  PRAGMA EXCEPTION_INIT(badEmail, -20222);
  l_debug number := 1;
  
  gv_subject    varchar2(500); -- subj отправляемого письма
  gv_maxSize    number := 50000000; -- максимальный размер вложения
  gv_alarm      number := 0;
  gv_catchSize  number := 0;
  gv_catchName  varchar2(150):='';
--------------------------------------------------------------------------------------------------------
procedure debugmsg(msg in varchar2)
is
begin
  if l_debug=1 then
    log_ovart(-1, 'emailsender_debug', msg);
  end if;
end;

--------------------------------------------------------------------------------------------------------
function getNameWOpath(p_str varchar2) return varchar2
is
  l_pos  number;
begin
  l_pos := instr(replace(p_str,'\','/'),'/',-1);
  return case when l_pos>0 then substr(p_str,l_pos+1) else p_str end;
end;

--------------------------------------------------------------------------------------------------------
FUNCTION GetEmail(p_user varchar2) return varchar2
is
begin
  case
    when upper(p_user) = 'SPARSHUKOV'   then return '<Sergey.Parshukov@MegaFon.ru>';
    when upper(p_user) = 'RKRIKUNOV'    then return '<ruslan.krikunov@MegaFon.ru>';
    when upper(p_user) = 'VIVAKIN'      then return '<vladimir.ivakin@MegaFon.ru>';
    when upper(p_user) = 'TARASENKO_SS' then return '<Sergey.Tarasenko@MegaFon.ru>';
    when upper(p_user) = 'LEVENETS_EE'  then return '<Evgeny.Levenets@MegaFon.ru>';
  else
    return '<Sergey.Parshukov@MegaFon.ru>';
  end case;
end;


--------------------------------------------------------------------------------------------------------
PROCEDURE put_header(NAME IN VARCHAR2, header IN VARCHAR2) AS
BEGIN
-- CL8ISO8859P5
-- CL8MSWIN1251
  utl_smtp.write_raw_data(g_mail_conn, 
                          utl_raw.cast_to_raw(NAME || ': ' || convert(header,'CL8MSWIN1251') || utl_tcp.crlf)
                         );
--  debugmsg(NAME || ': ' || header);
END;
--------------------------------------------------------------------------------------------------------
PROCEDURE put_data(data     IN VARCHAR2, 
                   chr_set  in varchar2 default 'CL8MSWIN1251',
                   use_CRLF in boolean  default true) 
IS
BEGIN
-- CL8ISO8859P5
-- CL8MSWIN1251
  if use_CRLF then
    utl_smtp.write_raw_data(g_mail_conn,
                            utl_raw.cast_to_raw(convert(data, chr_set)||UTL_TCP.CRLF));
--    dbms_output.put_line(data||UTL_TCP.CRLF);                            
  else
    utl_smtp.write_raw_data(g_mail_conn,
                            utl_raw.cast_to_raw(convert(data, chr_set)));
--    dbms_output.put_line(data);                            
  end if;  
END;
-------------------------------------------------------------------
-- пишем заголовок письма
procedure Push_Header(recpList IN TStringList,   p_subject IN varchar2)
is
  l_recpStr  varchar2(2000):='';
  l_single   varchar2(200):='';
  dd_date    varchar2(100):='';
begin
   if recpList is not null then 
     for i in recpList.first .. recpList.last loop
       l_single := recpList(i);
       if l_single not like '<%>' then
         --debugmsg('recipient not like <%>');
         l_single := '<'||l_single||'>';
       end if;
       utl_smtp.rcpt(g_mail_conn, l_single);        
       l_recpStr := l_recpStr||l_single;
       if i <> recpList.last then l_recpStr := l_recpStr||';'; end if;
     end loop;
   end if;
   if l_recpStr='' then 
     l_recpStr:=GetEmail(user); 
     utl_smtp.rcpt(g_mail_conn, l_recpStr);
   end if;
   utl_smtp.open_data(g_mail_conn);
   debugmsg('письмо для '||l_recpStr);
   put_header('MIME-Version','1.0');
   put_header('From',    g_sender );
   put_header('To',      l_recpStr);
   put_header('Subject', p_subject);

   if sys_context('jm_ctx', 'Reply-To') is not null then
     put_header('Reply-To',  sys_context('jm_ctx', 'Reply-To'));
     put_header('Errors-To', sys_context('jm_ctx', 'Reply-To'));
     put_header('Return-Path', sys_context('jm_ctx', 'Reply-To'));
   end if;

-- 2012/05/15 : вытаскиваем из контекста дополнительную информацию
   if sys_context('jm_ctx', 'job_id') is not null then
     put_header('X-JM-jobid',     sys_context('jm_ctx', 'job_id'));
     put_header('X-JM-object',    sys_context('jm_ctx', 'object'));
     put_header('X-JM-procedure', sys_context('jm_ctx', 'procedure'));
     begin
       select to_char(to_timestamp_TZ(dd_char,'dd.mm.yyyy hh24:mi:ss'),'dd Mon YYYY hh24:mi:ss TZHTZM', 'NLS_DATE_LANGUAGE=AMERICAN') into dd_date
         from (select sys_context('jm_ctx', 'job_start') dd_char from dual);
       put_header('X-JM-jobstart', dd_date);
     exception when others then null;
     end;
   end if;

   put_header('Content-Type','multipart/mixed; charset="windows-1251"; boundary="'|| g_mailBoundary ||'"');
end;

-------------------------------------------------------------------
-- пишем тело письма
procedure Push_Body(p_body in clob)
is
begin
   put_data(UTL_TCP.CRLF||'--' || g_mailBoundary);
   put_header('Content-Type', 'text/plain; charset="windows-1251"');
   put_header('Content-Language', 'ru');
   put_header('Content-Transfer-Encoding', '8bit');
   put_data(UTL_TCP.CRLF);
   put_data(to_char(p_body));   
   put_data('');
   put_data('--P.S.-----------------------------------------------------------------------------');
   put_data('Это письмо сгенерировано почтовым роботом.');
   put_data('Отправлено с сервера '||sys_context('USERENV','DB_NAME')||' ('||sys_context('USERENV','DB_UNIQUE_NAME')||')');
--   if sys_context('jm_ctx','footer1')<>'' then 
   put_data('');
   put_data(sys_context('jm_ctx','footer1'));
   put_data(sys_context('jm_ctx','footer2'));
   put_data(sys_context('jm_ctx','footer3'));
   put_data(sys_context('jm_ctx','footer4'));
   put_data(sys_context('jm_ctx','footer5'));
   put_data(sys_context('jm_ctx','footer6'));
--   end if;
end;

-------------------------------------------------------------------
-- добавляем аттач в письмо
procedure Push_attach(p_attach in clob, p_attach_name in varchar2, p_description in varchar2 default null)
is
   charBuffer    varchar2(2001);
   readAmount    number := 2000;
   wasRead       number := 0;
   readPos       number := 1;
   l_attach_name varchar2(150) := nvl(p_attach_name,'noname.txt');
   
begin
-- проверяем текстовые вложения
   if dbms_lob.getLength(p_attach)>0  then
       if dbms_lob.getLength(p_attach) > gv_maxSize then 
         gv_alarm := gv_alarm + 1;
         gv_catchName := p_attach_name;
       end if;
       debugmsg('Есть текстовые вложения : '||l_attach_name||'('||to_char(dbms_lob.getLength(p_attach))||')');
       
       -- записываем MIME заголовок для передоваемого файла
       put_data(utl_tcp.crlf||'--' || g_mailBoundary);
       put_header('Content-Type','text/plain; charset="windows-1251"; name="'||l_attach_name ||'"');
       put_header('Content-Language','ru');
       put_header('Content-Transfer-Encoding','8bit');
       put_header('Content-Disposition','attachment; filename="' || l_attach_name ||'"');
       if p_description is not null then 
         put_header('Content-Description',p_description);
       end if;
       put_data('');--utl_tcp.crlf);

       -- записываем сам файл
       readAmount := 2000;    wasRead    := 0;     readPos    := 1;
       begin
         loop
           wasRead := readAmount;
           dbms_lob.read(p_attach,wasRead,readPos,charBuffer);
           put_data(data=>charBuffer, use_CRLF => false);
           readPos := readPos + wasRead;
         end loop;
       exception WHEN NO_DATA_FOUND THEN
         null;
       end;
   end if;
end;

-------------------------------------------------------------------
-- добавляем аттач в письмо
procedure Push_attach(p_attach in blob, p_attach_name in varchar2, p_description in varchar2 default null)
is
   charBuffer    raw(2400);
   readAmount    number := 2400;
   wasRead       number := 0;
   readPos       number := 1;
   l_attach_name varchar2(150) := nvl(p_attach_name,'noname.zip');
   rawBuffer     raw(8000);
   loopcounter   number;
begin
-- проверяем бинарные вложения
   if dbms_lob.getLength(p_attach)>0  then
       if p_description like '%with pass%' then
         debugmsg('Есть бинарные вложения с паролем : '||l_attach_name||'('||to_char(dbms_lob.getLength(p_attach))||')');
       else
         debugmsg('Есть бинарные вложения : '||l_attach_name||'('||to_char(dbms_lob.getLength(p_attach))||')');
       end if;
       if dbms_lob.getLength(p_attach) > gv_maxSize then 
         gv_alarm := gv_alarm + 1;
         gv_catchName := p_attach_name;
       end if;
       
       if upper(l_attach_name)='ZIP' then l_attach_name := 'noname.zip'; end if;
       -- записываем MIME заголовок для передоваемого файла
--       put_data('');
       put_data(utl_tcp.crlf||'--' || g_mailBoundary);
       put_header('Content-Type','application/octet-stream; name="'||l_attach_name ||'"');
       put_header('Content-Transfer-Encoding','base64');
       put_header('Content-Disposition','attachment; filename="' || l_attach_name ||'"');
       if p_description is not null then 
         put_header('Content-Description',p_description);
       end if;
       put_data('');

       -- записываем сам файл
       readAmount := 2400;    wasRead    := 0;     readPos    := 1;
       begin
         loop
           wasRead := readAmount;
           dbms_lob.read(p_attach,wasRead,readPos,charBuffer);
           rawBuffer := utl_encode.base64_encode(charBuffer);
           utl_smtp.write_raw_data(g_mail_conn, rawBuffer);
           readPos := readPos + wasRead;
           rawBuffer := ''; charBuffer := '';
         end loop;
       exception WHEN NO_DATA_FOUND THEN
         null;
       end;
       
   end if;
end;

--------------------------------------------------------------------------------------------------------
procedure SendToPsv(p_subject IN varchar2, p_body in varchar2)
is
  res number;
begin
  SendTo('<Sergey.parshukov@megafon.ru>', p_subject, p_body);
end;


--------------------------------------------------------------------------------------------------------
Procedure AlarmSizeExceed(p_size number, p_name varchar2)
is
  l_recipient   varchar2(200);
begin
  if p_size>gv_maxSize then 
    l_recipient := coalesce(sys_context('jm_ctx', 'Reply-To'), GetEmail(user));
    SendTo(l_recipient, 
         'ВНИМАНИЕ : превышение порога '||case when sys_context('jm_ctx', 'job_id') is not null then 'job_id='||sys_context('jm_ctx', 'job_id') else '' end,
         'Внимание!'||chr(13)||chr(10)||
         'Для отчета job_id='||sys_context('jm_ctx', 'job_id')||chr(13)||chr(10)||
         'с темой='||gv_subject||chr(13)||chr(10)||
         '('||sys_context('jm_ctx', 'object')||
              case when sys_context('jm_ctx', 'object') is not null then '.' else '' end||
              sys_context('jm_ctx', 'procedure')||')'||chr(13)||chr(10)||
         'превышен максимальный размер вложения "'||p_name||'" ('||p_size||' байт). Наблюдаемый порог - '||to_char(gv_maxSize)||chr(13)||chr(10)||
         'всего превышаюших вложений - '||to_char(gv_alarm)
         );
  end if;
exception
  when others then 
    debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
end;


--------------------------------------------------------------------------------------------------------
procedure SendTo(
       p_recipient IN varchar2,
       p_subject IN varchar2,
       p_body in varchar2)
is
  p_dat date := sysdate;
begin
   g_mail_conn := utl_smtp.open_connection(g_mailhost, 25);
   utl_smtp.helo(g_mail_conn, g_mailhost);
   utl_smtp.mail(g_mail_conn, g_sender);
   
   -- заголовок
   Push_Header(TStringList(p_recipient), p_subject );
   -- пишем тело письма
   Push_Body(to_clob(p_body));

   put_data(UTL_TCP.CRLF||'--' || g_mailBoundary||'--'||UTL_TCP.CRLF);
   utl_smtp.close_data(g_mail_conn);
   utl_smtp.quit(g_mail_conn);
EXCEPTION
   when others then
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     raise;
end;

--------------------------------------------------------------------------------------------------------
function getMsisdnByEmail(p_recip in varchar2) return varchar2
is
  l_ans varchar2(20);
begin
  select msisdn into l_ans from j_recipient_sms where recipient=lower(p_recip) and enabled=1;
  return l_ans;
exception
  when no_data_found then
     return null;
end;

--------------------------------------------------------------------------------------------------------
FUNCTION SendEmailWithAttach(
   p_recipient   IN TStringList,
   p_subject     IN varchar2,
   p_body        in clob)
 RETURN number
is
  cb TClobList := null;
begin
 return SendEmailWithAttach(p_recipient, 
                            p_subject, 
                            p_body, 
                            null, 
                            cb,
                            false,
                            null);
end;

--------------------------------------------------------------------------------------------------------
FUNCTION SendEmailWithAttach(
   p_recipient   IN varchar2,
   p_subject     IN varchar2,
   p_body        in clob ,
   p_attach_name in varchar2,
   p_attach      in clob)
 RETURN number
is
begin
 return SendEmailWithAttach(TStringList('<'||p_recipient||'>'), 
                            p_subject, 
                            p_body, p_attach_name, p_attach);
end;

--------------------------------------------------------------------------------------------------------
FUNCTION SendEmailWithAttach(
   recpList      IN TStringList,
   p_subject     IN varchar2,
   p_body        in clob ,
   p_attach_name in varchar2,
   p_attach      in clob)
 RETURN number
is
begin
   return SendEmailWithAttach(recpList, 
                            p_subject, 
                            p_body, TStringList(p_attach_name), TClobList(p_attach),
                            false, null);
end;

--------------------------------------------------------------------------------------------------------
FUNCTION SendEmailWithAttach(
   recpList         IN  TStringList,
   p_subject        IN  varchar2,
   p_body           in  clob ,
   p_rl             in  TRItemList,
   p_isArch         in  boolean    default false)
 RETURN number
is
  l_body    clob:=p_body;
  l_str     varchar2(100);
  l_arch    number  := case when p_isArch then 1 else 0 end;
  ri        TRItem;
  l_msisdn  varchar2(100);
  lb blob;
  l_EmailsumAttachSize number:=0;
  l_EmailmaxAttachSize number:=0;
begin
   g_mail_conn := utl_smtp.open_connection(g_mailhost, 25);
   utl_smtp.helo(g_mail_conn, g_mailhost);
   utl_smtp.mail(g_mail_conn, g_sender);
   gv_subject := p_subject;
   gv_alarm   := 0;
      
   -- заголовок
   Push_Header(recpList, p_subject );

   -- пишем тело письма
   if p_rl is not null and p_rl.count>0 then
     for i in p_rl.first .. p_rl.last
     loop
       if bitand(p_rl(i).DataType,4+8+16)>0 and bitand(p_rl(i).sendMethod,1)>0 then 
         dbms_lob.append(l_Body, to_clob(p_rl(i).GetDataV||chr(13)||chr(10)) );
       end if;
     end loop;
   end if;
   Push_Body(p_body);

   -- проверяем вложения
   if p_rl is not null and p_rl.count>0 then
     for i in p_rl.first .. p_rl.last
     loop
       ri := p_rl(i);
       if bitand(ri.DataType,1+2)>0 and bitand(ri.sendMethod,1)>0 then 
         if p_isArch or bitand(ri.DataType,2)>0 then 
           lb := ri.GetDataB(l_arch);
           l_EmailsumAttachSize := l_EmailsumAttachSize + length(lb);
           l_EmailmaxAttachSize := greatest(l_EmailmaxAttachSize, length(lb));
           Push_attach(ri.GetDataB(l_arch), getNameWOpath(ri.itemName)||'.zip');
         elsif bitand(ri.DataType,1)=1 then 
           l_EmailsumAttachSize := l_EmailsumAttachSize + length(ri.dc);
           l_EmailmaxAttachSize := greatest(l_EmailmaxAttachSize, length(ri.dc));
           Push_attach(ri.dc, getNameWOpath(ri.itemName)||'.'||ri.itemExt);
         end if;
         if p_isArch and ri.archPass<>'' and sys_context('jm_ctx','dont_send_password')is null then 
           for e in recpList.first .. recpList.last
           loop
             l_msisdn := ri.getMsisdnByRcpt(recpList(e));
             utils.SendSms(l_msisdn, 'пароль к архиву "'||getNameWOpath(ri.itemName)||'.zip" : '||ri.archPass);
             debugmsg('Уведомление-пароль для '||recpList(e)||' направлено по смс('||l_msisdn||')');           
           end loop;
         end if;
       end if;
     end loop;
   end if;
   
   put_data(UTL_TCP.CRLF||'--' || g_mailBoundary||'--');
   utl_smtp.close_data(g_mail_conn);
   utl_smtp.quit(g_mail_conn);
   
   if gv_alarm>0 then
     AlarmSizeExceed(gv_catchSize, gv_catchName);
   end if;
   
   return 0;
exception
   when badEmail then
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     raise;
   WHEN utl_smtp.transient_error OR utl_smtp.permanent_error THEN
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     return -1;
   when others then
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     return -1;
end;

--------------------------------------------------------------------------------------------------------
FUNCTION SendEmailWithAttach(
   recpList         IN  TStringList,
   p_subject        IN  varchar2,
   p_body           in  clob ,
   p_attachNameList in  TStringList,
   p_attachList     in  TClobList,
   p_isArch         in  boolean    default false,
   p_archPass       in  varchar2   default null)
 RETURN number
is
  l_msisdn      varchar2(100);
  l_zipname     varchar2(100);
  l_archPass    varchar2(100) := p_archPass;
  lb blob;
  l_EmailsumAttachSize number:=0;
  l_EmailmaxAttachSize number:=0;
begin
   g_mail_conn := utl_smtp.open_connection(g_mailhost, 25);
   utl_smtp.helo(g_mail_conn, g_mailhost);
   utl_smtp.mail(g_mail_conn, g_sender);
   gv_subject := p_subject;
   gv_alarm   := 0;
   
   -- заголовок
   Push_Header(recpList, p_subject );

   -- пишем тело письма
   Push_Body(p_body);

   -- проверяем вложения
   if p_attachList is not null and p_attachList.count>0 then
--     debugmsg('есть вложения '||to_char(p_attachList.count));
     for i in p_attachList.first .. p_attachList.last loop
       if p_isArch then 
         l_zipname := substr(p_attachNameList(i),1,instr(p_attachNameList(i),'.'))||'zip';
         if p_archPass is null then 
           lb := pck_zip.clob_compress(p_attachList(i), p_attachNameList(i));
           l_EmailsumAttachSize := l_EmailsumAttachSize + length(lb);
           l_EmailmaxAttachSize := greatest(l_EmailmaxAttachSize, length(lb));
           Push_attach(lb, l_zipname, 'ZIP archive('||to_char(i)||' attachement)' );
         else
           if lower(p_archPass) = 'схема-1' then 
             l_archPass := recpList(1); 
           end if;
           lb := pck_zip.clob_aes_compress(p_attachList(i), p_attachNameList(i), l_archPass);
           l_EmailsumAttachSize := l_EmailsumAttachSize + length(lb);
           l_EmailmaxAttachSize := greatest(l_EmailmaxAttachSize, length(lb));
           Push_attach(lb, l_zipname, 'ZIP archive with pass('||to_char(i)||' attachement)' );
           for e in recpList.first .. recpList.last loop
             l_msisdn := getMsisdnByEmail(recpList(e));
             if sys_context('jm_ctx','dont_send_password')is null then 
                 if l_msisdn is not null then 
                   utils.SendSms(l_msisdn, 'пароль к архиву "'||l_zipname||'" : '||l_archPass);
                   debugmsg('Уведомление-пароль для '||recpList(e)||' направлено по смс('||l_msisdn||')');
                 else
                   SendTo(recpList(e), p_subject||'-пароль', 'пароль к архиву "'||l_zipname||'" : '||l_archPass);         
                   debugmsg('Уведомление-пароль для '||recpList(e)||' направлено по e-mail');
                 end if;
             else
               debugmsg('Отправка уведомление-пароля запрещена');
             end if;
           end loop;
         end if;
       else
         l_EmailsumAttachSize := l_EmailsumAttachSize + length(p_attachList(i));
         l_EmailmaxAttachSize := greatest(l_EmailmaxAttachSize, length(p_attachList(i)));
         Push_attach(p_attachList(i), p_attachNameList(i) );
       end if;
     end loop;
     if l_EmailSumAttachSize>0 then 
       j_manager.addp_set(nvl(sys_context('jm_ctx', 'job_id'),0), 'default', 'EmailSumAttachSize', to_char(l_EmailSumAttachSize));
       j_manager.addp_set(nvl(sys_context('jm_ctx', 'job_id'),0), 'default', 'EmailMaxAttachSize', to_char(l_EmailMaxAttachSize));
     end if;
   end if;
   
   put_data(UTL_TCP.CRLF||'--' || g_mailBoundary||'--');
   utl_smtp.close_data(g_mail_conn);
   utl_smtp.quit(g_mail_conn);
   return 0;
exception
   when badEmail then
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     raise;
   WHEN utl_smtp.transient_error OR utl_smtp.permanent_error THEN
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     return -1;
   when others then
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     return -1;
end;

--------------------------------------------------------------------------------------------------------
FUNCTION SendEmailWithAttach(
   recpList         IN  TStringList,
   p_subject        IN  varchar2,
   p_body           in  clob ,
   p_attachNameList in  TStringList,
   p_attachList     in  TBlobList,
   p_isArch         in  boolean    default false,
   p_archPass       in  varchar2   default null)
 RETURN number
is
  l_msisdn      varchar2(100);
  l_zipname     varchar2(100);
  l_archPass    varchar2(100) := p_archPass;
  
  lb blob;
  l_EmailsumAttachSize number:=0;
  l_EmailmaxAttachSize number:=0;
begin
   g_mail_conn := utl_smtp.open_connection(g_mailhost, 25);
   utl_smtp.helo(g_mail_conn, g_mailhost);
   utl_smtp.mail(g_mail_conn, g_sender);
   gv_subject := p_subject;
   gv_alarm   := 0;
   
   -- заголовок
   Push_Header(recpList, p_subject );

   -- пишем тело письма
   Push_Body(p_body);

   -- проверяем вложения
   if p_attachList is not null and p_attachList.count>0 then
--     debugmsg('есть вложения '||to_char(p_attachList.count));
     for i in p_attachList.first .. p_attachList.last loop
       if p_isArch then 
         l_zipname := substr(p_attachNameList(i),1,instr(p_attachNameList(i),'.'))||'zip';
         --if p_archPass is null then 
           lb := pck_zip.blob_compress(p_attachList(i), p_attachNameList(i));
           l_EmailsumAttachSize := l_EmailsumAttachSize + length(lb);
           l_EmailmaxAttachSize := greatest(l_EmailmaxAttachSize, length(lb));
           Push_attach(lb, l_zipname, 'ZIP archive('||to_char(i)||' attachement)' );
         /*else
           if lower(p_archPass) = 'схема-1' then 
             l_archPass := recpList(1); 
           end if;
           Push_attach(pck_zip.clob_aes_compress(p_attachList(i), p_attachNameList(i), l_archPass),l_zipname, 'ZIP archive with pass('||to_char(i)||' attachement)' );
           for e in recpList.first .. recpList.last loop
             l_msisdn := getMsisdnByEmail(recpList(e));
             if sys_context('jm_ctx','dont_send_password')is null then 
                 if l_msisdn is not null then 
                   utils.SendSms(l_msisdn, 'пароль к архиву "'||l_zipname||'" : '||l_archPass);
                   debugmsg('Уведомление-пароль для '||recpList(e)||' направлено по смс('||l_msisdn||')');
                 else
                   SendTo(recpList(e), p_subject||'-пароль', 'пароль к архиву "'||l_zipname||'" : '||l_archPass);         
                   debugmsg('Уведомление-пароль для '||recpList(e)||' направлено по e-mail');
                 end if;
             else
               debugmsg('Отправка уведомление-пароля запрещена');
             end if;
           end loop;
         end if;*/
       else
         l_EmailsumAttachSize := l_EmailsumAttachSize + length(p_attachList(i));
         l_EmailmaxAttachSize := greatest(l_EmailmaxAttachSize, length(p_attachList(i)));
         Push_attach(p_attachList(i), p_attachNameList(i) );
       end if;
     end loop;
     if l_EmailSumAttachSize>0 then 
       j_manager.addp_set(nvl(sys_context('jm_ctx', 'job_id'),0), 'default', 'EmailSumAttachSize', to_char(l_EmailSumAttachSize));
       j_manager.addp_set(nvl(sys_context('jm_ctx', 'job_id'),0), 'default', 'EmailMaxAttachSize', to_char(l_EmailMaxAttachSize));
     end if;
   end if;
   
   put_data(UTL_TCP.CRLF||'--' || g_mailBoundary||'--');
   utl_smtp.close_data(g_mail_conn);
   utl_smtp.quit(g_mail_conn);
   return 0;
exception
   when badEmail then
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     raise;
   WHEN utl_smtp.transient_error OR utl_smtp.permanent_error THEN
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     return -1;
   when others then
     debugmsg(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
     utl_smtp.close_data(g_mail_conn);
     utl_smtp.quit(g_mail_conn);
     return -1;
end;


END;
--------------------------------------------------------------------------------
/
