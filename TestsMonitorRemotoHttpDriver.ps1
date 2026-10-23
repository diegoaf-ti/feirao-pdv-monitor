#requires -Version 5.1
# Driver HTTP .NET com WebRequest fixture registrada somente neste processo de teste.
# Nenhum socket, certificado, rede ou DPAPI reais. Mantem callback TLS padrao.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0;
$directory=Split-Path -Parent $MyInvocation.MyCommand.Path;Import-Module (Join-Path $directory 'PdvMonitor.Remoto.Transporte.psm1') -Force;$module=Get-Module PdvMonitor.Remoto.Transporte;
$source=@'
using System;
using System.IO;
using System.Net;
using System.Threading;
namespace PdvRemoteHttpFixture {
 public sealed class Result : IAsyncResult {
  readonly ManualResetEvent handle; public Result(bool ready){handle=new ManualResetEvent(ready);} public object AsyncState{get{return null;}} public WaitHandle AsyncWaitHandle{get{return handle;}} public bool CompletedSynchronously{get{return true;}} public bool IsCompleted{get{return handle.WaitOne(0);}}
 }
 public sealed class HangingStream : MemoryStream { public override IAsyncResult BeginRead(byte[] b,int o,int c,AsyncCallback cb,object state){return new Result(false);} }
 public sealed class Response : WebResponse {
  public HttpStatusCode StatusCode{get;set;} public bool Hang; public int Reads; public long Size; public string Type="application/xml; charset=utf-8";
  readonly WebHeaderCollection headers=new WebHeaderCollection(); public override WebHeaderCollection Headers{get{return headers;}}
  public override long ContentLength{get{return Size;}set{Size=value;}} public override string ContentType{get{return Type;}set{Type=value;}}
  public override Stream GetResponseStream(){Reads++;return Hang?(Stream)new HangingStream():new MemoryStream(System.Text.Encoding.UTF8.GetBytes("<ok/>"));}
 }
 public sealed class Request : WebRequest {
  public Response Reply=new Response{StatusCode=HttpStatusCode.OK,Size=5}; public MemoryStream Body=new MemoryStream(); public bool Aborted;
  public bool AllowAutoRedirect{get;set;} public int ReadWriteTimeout{get;set;} public DecompressionMethods AutomaticDecompression{get;set;} public string Accept{get;set;} public bool KeepAlive{get;set;}
  public override string Method{get;set;} public override string ContentType{get;set;} public override long ContentLength{get;set;} public override int Timeout{get;set;} public override bool UseDefaultCredentials{get;set;} public override bool PreAuthenticate{get;set;}
  WebHeaderCollection headers=new WebHeaderCollection(); public override WebHeaderCollection Headers{get{return headers;}set{headers=value;}}
  public override IAsyncResult BeginGetRequestStream(AsyncCallback cb,object state){return new Result(true);} public override Stream EndGetRequestStream(IAsyncResult r){return Body;}
  public override IAsyncResult BeginGetResponse(AsyncCallback cb,object state){return new Result(true);} public override WebResponse EndGetResponse(IAsyncResult r){return Reply;}
  public override void Abort(){Aborted=true;}
 }
 public sealed class Factory : IWebRequestCreate {public static Request Current;public WebRequest Create(Uri uri){return Current;}}
}
'@
Add-Type -TypeDefinition $source -IgnoreWarnings -WarningAction SilentlyContinue;
if(-not [Net.WebRequest]::RegisterPrefix('https://pdv-http-fixture.invalid/',(New-Object PdvRemoteHttpFixture.Factory))){throw 'Fixture prefix';}
$script:Checks=0;
function Assert-Driver($Condition,[string]$Message){$script:Checks++;if(-not $Condition){throw $Message;}}
function Invoke-Driver([string]$Method='GET',[string]$Body=''){return (& $module {param($Method,$Text);Invoke-PdvRemoteBoundedHttp 'https://pdv-http-fixture.invalid/typed' 'Bearer FAKE' $Method ([Text.Encoding]::UTF8.GetBytes($Text));} $Method $Body);}
$before=[Net.ServicePointManager]::ServerCertificateValidationCallback;
$request=New-Object PdvRemoteHttpFixture.Request;[PdvRemoteHttpFixture.Factory]::Current=$request;$result=Invoke-Driver 'POST' '{"status":"closed"}';
Assert-Driver ($result.Status -eq 200 -and [Text.Encoding]::UTF8.GetString($result.Bytes) -ceq '<ok/>') 'Driver nao leu bytes.';
Assert-Driver ($request.Aborted -and -not $request.AllowAutoRedirect -and $request.Accept -ceq 'application/xml' -and -not $request.UseDefaultCredentials) 'Driver relaxou padroes ou deixou requisicao.';
Assert-Driver ([Text.Encoding]::UTF8.GetString($request.Body.ToArray()) -ceq '{"status":"closed"}') 'POST mudou payload.';
$request=New-Object PdvRemoteHttpFixture.Request;$request.Reply.StatusCode=[Net.HttpStatusCode]::Found;[PdvRemoteHttpFixture.Factory]::Current=$request;$result=Invoke-Driver;
Assert-Driver ($result.Status -eq 302 -and $null -eq $result.Bytes -and $request.Reply.Reads -eq 0 -and $request.Aborted) 'Redirect leu corpo ou foi seguido.';
foreach($kind in @('size','encoding','contenttype','hang')){
 $request=New-Object PdvRemoteHttpFixture.Request;
 switch($kind){'size'{$request.Reply.Size=8193;}'encoding'{$request.Reply.Headers['Content-Encoding']='gzip';}'contenttype'{$request.Reply.Type='text/html';}'hang'{$request.Reply.Hang=$true;}}
 [PdvRemoteHttpFixture.Factory]::Current=$request;$clock=[Diagnostics.Stopwatch]::StartNew();$failed=$false;
 try{Invoke-Driver|Out-Null;}catch{$failed=$true;Assert-Driver ($_.Exception.Message -ceq 'RemoteTransportUnavailable') 'Driver vazou detalhe de excecao.';}finally{$clock.Stop();}
 Assert-Driver ($failed -and $request.Aborted) ('Driver aceitou '+$kind);
 if($kind -ceq 'hang'){Assert-Driver ($clock.ElapsedMilliseconds -lt 6000 -and $clock.ElapsedMilliseconds -ge 3500) 'Prazo total nao foi aplicado ao stream.';}
}
Assert-Driver ([object]::ReferenceEquals($before,[Net.ServicePointManager]::ServerCertificateValidationCallback)) 'Driver substituiu validacao TLS.';
Write-Output ('PASS: '+$Checks+' verificacoes driverHTTP/.NET com fixtures sem rede.');
