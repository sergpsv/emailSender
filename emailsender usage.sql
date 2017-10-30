-- ========================================================================
/*  1) выбираем произвольную цифру - уникальную в рамках сеанса - 
       это будет номер письма
    2) в таблицу emailbody вставляем строки тела письма с указанным номером
    3) в таблицу emailbody_att вставляем строки с полем CLOB в котором будет вложения
       сколько строк - столько вложений. расширение для тестового файла по умолчанию - ТХТ
       если необходимо другое - обновляем поле ext_c для данной строки
    4) вызываем процедуру для архивации - результат помещается в ту же строку в столбец B_LOB
       если необходимо отправить только архив, удаяем данные из столбца CLOB 
    5) отправляем письмо вызовом метода SendEMailBodyTo                                      
       - при отправке вложений сначала идут текстовые потом бинарные.
    6) очищаем за собой использованые строки таблиц emailbody и emailbody_att

единственное неудобство - при архивировании используется кодировка базы,
на текущий момент - это ISO-8859-1

*/
-- ========================================================================
-- код для создания необходимых таблиц

-- создание sequence
CREATE SEQUENCE idanytable_seq
  INCREMENT BY 1
  START WITH 1
  MINVALUE 1
  MAXVALUE 999999999999999999999999999
  NOCYCLE
  NOORDER
  CACHE 20
/

-- таблица сообщений
CREATE TABLE emailbody
    (sessionid   VARCHAR2(20) DEFAULT sys_context('UserEnv','SessionID'),
     mail_num    NUMBER       DEFAULT 0,
     iid         NUMBER,
     txt         VARCHAR2(500))
  PCTFREE     0
/

-- триггер для упорядочивания строк сообщения
CREATE OR REPLACE TRIGGER emailbody_iid
 BEFORE
  INSERT
 ON emailbody
REFERENCING NEW AS NEW OLD AS OLD
 FOR EACH ROW
begin
  select idanytable_seq.nextval into :new.iid from dual;
end;
/

-- таблица вложений в сообщение
CREATE TABLE emailbody_att
    (sessionid   VARCHAR2(20) DEFAULT sys_context('UserEnv','SessionID'),
     mail_num    NUMBER       DEFAULT 0,
     iid         number,
     c_lob       clob,
     b_lob       blob,
     filename    varchar2(250) default to_char(sys_context('UserEnv','SessionID'))||'_'||to_char(sysdate,'yyyymmddhh24miss'),
     ext_c 			 varchar2(10) default '.txt',
     ext_b 			 varchar2(10) default '.zip'
     )
  PCTFREE     0
/


-- триггер для упорядочивания порядка вложений
CREATE OR REPLACE TRIGGER emailbody_att_iid
 BEFORE
  INSERT
 ON emailbody_att
REFERENCING NEW AS NEW OLD AS OLD
 FOR EACH ROW
begin
  select idanytable_seq.nextval into :new.iid from dual;
end;
/





-- ========================================================================
-- пример использования

------------------------------------- 
-- 1) выбрали цифру 11
------------------------------------- 
-- 2) вставляем строки
insert into emailbody (mail_num, txt) values (11, 'Текст письма для теста');
insert into emailbody (mail_num, txt) values (11, 'строка 11111');
insert into emailbody (mail_num, txt) values (11, 'строка 22222');

------------------------------------- 
-- 3) 
insert into emailbody_att (mail_num, filename, c_lob)
values (11, 'MyFileName', to_clob('************************************************************

тестовая строка по русски

Fatal NI connect error 12560, connecting to:
 (DESCRIPTION=(ADDRESS=(PROTOCOL=BEQ)(PROGRAM=oracle)(ARGV0=oracleORCL)
                 (ARGS=''(DESCRIPTION=(LOCAL=YES)(ADDRESS=(PROTOCOL=beq)))'')
              )
  (CONNECT_DATA=(SID=ORCL))
 )
  Информация о версии:
	TNS for 32-bit Windows: Версия 9.2.0.1.0 - Production
	Oracle Bequeath NT Protocol Adapter for 32-bit Windows: Version 9.2.0.1.0 - Production
	Windows NT TCP/IP NT Protocol Adapter for 32-bit Windows: Version 9.2.0.1.0 - Production
    TNS-12560: TNS:protocol adapter error
    nt OS err code: 0'));

------------------------------------- 
-- 3) при необходимости сделать append данных в поле c_lob делаем следующее
declare 
  b  clob;
begin
  select c_lob into b from emailbody_att where mail_num=11 for update;
  DBMS_LOB.APPEND(b, to_clob(convert('********************************************', 'CL8MSWIN1251')));
  commit;
end;
/

------------------------------------- 
-- 4) при необходимости - архивируем
declare 
  b  blob;
  b2 blob;
  fn emailbody_att.filename%type;
begin
  select utl_raw.cast_to_raw(c_lob), filename||nvl(ext_c,'.txt') into b, fn from emailbody_att where mail_num=11;
  b2 := sparshukov.pck_zip.blob_compress(b, fn);
  update emailbody_att set b_lob = b2 where mail_num=11;
  commit;
end;
/


------------------------------------- 
-- 5) отправляем письмо
DECLARE
  res  NUMBER;
BEGIN
  res := emailsender.sendemailbodyto('Sergey.parshukov@megafonkavkaz.ru','Тестовое письмо',sys_context('UserEnv','SessionID'),11);
  if res = 0 then
  	dbms_output.put_line('Сообщение отправлено успешно!');
  else
  	dbms_output.put_line('Ошибка при отправке письма: '||res);
  end if;
EXCEPTION
WHEN OTHERS THEN
  dbms_output.put_line(SubStr('Error '||TO_CHAR(SQLCODE)||': '||SQLERRM, 1, 255));
END;


------------------------------------- 
-- 6) чистим таблицы
delete from emailbody     where session_id = sys_context('UserEnv','SessionID') and mail_num=11;
delete from emailbody_att where session_id = sys_context('UserEnv','SessionID') and mail_num=11;


------------------------------------- 
-- 0) отправляем письмо
DECLARE
  res  NUMBER;
  ss   TStringList;
BEGIN
  res:= emailsender_2.sendemailwithattach(recpList=> TStringList('<Sergey.parshukov@megafon.ru>'),
                                        p_subject=>'Test subs на 2 адреса',
                                        p_body=>to_clob('"тестовое содержание" '),
                                        p_attach_name=>null,
                                        p_attach=>null);

  dbms_output.put_line(res);
EXCEPTION
WHEN OTHERS THEN
  dbms_output.put_line(dbms_utility.format_error_stack()||chr(13)||chr(10)||dbms_utility.format_error_backtrace());
END;


-- select utl_inaddr.get_host_address from dual
------------------------------------- 
-- 0) отправляем письмо
DECLARE
  res  NUMBER;
  ss   TStringList;
  c clob;
  b blob;
  s varchar2(256);
BEGIN
  c := get_clob('select * from drop_lee_pers_balance_result union all select * from drop_lee_pers_balance_result'); --select * from user_tables where rownum<=10');
--  s := pck_zip.clob_compress(c,'temp.xml', b);
  res:= emailsender_test.sendemailwithattach(
                                          recpList  => TStringList('<Sergey.parshukov@megafon.ru>'),
                                          p_subject => 'emailsender_test size ('||length(c)||')',
                                          p_body    => to_clob('тестовое содержание. Отправка с '||utl_inaddr.get_host_address),
                                          p_rl      => TRItemList(TRItem.iCreate(c, 'testsendsize')),
                                          p_isArch  => false
                                        );

  dbms_output.put_line('функция вернула '||res||'. Отправка с'||utl_inaddr.get_host_address);
EXCEPTION
WHEN OTHERS THEN
  dbms_output.put_line(SubStr('Error '||TO_CHAR(SQLCODE)||': '||SQLERRM, 1, 255));
END;
/



-- 0) отправляем письмо
DECLARE
  res  NUMBER;
  ss   TStringList;
BEGIN
  emailsender.sendTo('<Sergey.parshukov@megafon.ru>', --Eduard.Pulatov@megafonkavkaz.ru>',
                                        'Тест подписи AUTOREPORT c ',
                                        'IP-adresses баз с которых роботы отправляют отчеты '||chr(13)||chr(10)||
                                                        'STAT = HOST = 10.61.41.4'||chr(13)||chr(10)||
                                                        'BISDB = HOST = 10.61.41.30'||chr(13)||chr(10)||
                                                        'PRPDB = HOST = 10.61.41.4'||chr(13)||chr(10)||
                                                        'VORONDB = HOST = 10.61.41.40'||chr(13)||chr(10)||
                                                        'DWHVRN = HOST = 10.61.41.66'||chr(13)||chr(10)
                                       );

  dbms_output.put_line(res);
EXCEPTION
WHEN OTHERS THEN
  dbms_output.put_line(SubStr('Error '||TO_CHAR(SQLCODE)||': '||SQLERRM, 1, 255));
END;
/

select job_id, CLIENT_INFO, AUTHOR, navi_date, recipients,ATTACHNAMELIST,  ATTACHCLOBLIST from not_sended_report where job_id= 315

desc not_sended_report
select * from v_tlog order by iid

'STAT = HOST = 10.61.41.4'||chr(13)||chr(10)||
'BISDB = HOST = 10.61.41.30'||chr(13)||chr(10)||
'PRPDB = HOST = 10.61.41.4'||chr(13)||chr(10)||
'VORONDB = HOST = 10.61.41.40'||chr(13)||chr(10)||
'DWHVRN = HOST = 10.61.41.66'||chr(13)||chr(10)




select 
count (distinct SUBS_IDENTITY) as subs_amount
    from gup_qos.gup_profiles@tomks d 
    where  
     sysdate between start_date and end_Date
    and gsrv_gsrv_id=3

