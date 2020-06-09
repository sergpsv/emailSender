declare
  res    number        := 0;
  msg    varchar2(200) := '';
  p_ndat date          := sysdate;
begin
  dbms_output.put_line('p_ndat='||to_char(p_ndat,'dd.mm.yyyy hh24:mi:ss'));

  res := emailsender.sendemailwithattach(
                  recplist         => TSTRINGLIST('<youremailinbracket@domain.ru>'),
                  p_subject        => 'test sending '||to_char(p_ndat,'dd.mm.yyyy hh24:mi:ss')||' by sendemailwithattach',
                  p_body           => to_clob('отправлено из схемы '||user||chr(13)||chr(10)||'через '||emailsender.g_mailhost),
                  p_attachnamelist => TstringList('проба.txt'),
                  p_attachlist     => TClobList(to_clob('а вот и начиночка!!!')),
                  p_isarch         => false,
                  p_archpass       => null);
                  
  dbms_output.put_line(res);
exception
  when others then
    dbms_output.put_line(SQLCODE ||' '||SQLERRM);
end;


