// No networking, certificate-store imports or shared identities. Framework 4.6.2 / C# 5.
// Legacy X509 APIs are required by Framework 4.6.2; no certificate store is modified.
#pragma warning disable
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;

namespace Conecta.PdvRemoteEnrollment {
  public sealed class PublicRequest {
    public string AgentId, RequestId, CsrPem, PublicKeySha256;
  }
  public sealed class IssuedCertificate {
    public string CertificateSha256, PublicKeySha256, NotAfter;
  }
  public static class CryptoV1 {
    private static readonly byte[] RsaAlgorithm = new byte[] { 0x30,13,6,9,0x2a,0x86,0x48,0x86,0xf7,13,1,1,1,5,0 };
    private static readonly byte[] Sha256Algorithm = new byte[] { 0x30,13,6,9,0x2a,0x86,0x48,0x86,0xf7,13,1,1,11,5,0 };
    public static void AssertId(string value) {
      if (value == null || !Regex.IsMatch(value, "\\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\z")) throw new InvalidOperationException("RemoteEnrollmentInvalidIdentity");
    }
    private static byte[] Join(params byte[][] parts) {
      int length=0; foreach(byte[] part in parts) length=checked(length+part.Length);
      byte[] result=new byte[length]; int offset=0; foreach(byte[] part in parts) { Buffer.BlockCopy(part,0,result,offset,part.Length); offset+=part.Length; } return result;
    }
    private static byte[] Tlv(byte tag, byte[] value) {
      int n=value.Length; List<byte> header=new List<byte>(); header.Add(tag);
      if(n<128) header.Add((byte)n); else { List<byte> length=new List<byte>(); while(n>0) { length.Insert(0,(byte)n); n >>= 8; } header.Add((byte)(128|length.Count)); header.AddRange(length); }
      return Join(header.ToArray(),value);
    }
    private static byte[] Integer(byte[] number) {
      if(number==null || number.Length==0) throw new InvalidOperationException("RemoteEnrollmentInvalidRsa");
      int offset=0; while(offset<number.Length-1 && number[offset]==0) offset++;
      byte[] value=new byte[number.Length-offset+((number[offset]&128)!=0 ? 1 : 0)]; Buffer.BlockCopy(number,offset,value,value.Length-(number.Length-offset),number.Length-offset); return Tlv(2,value);
    }
    private static byte[] Subject(string agentId) { AssertId(agentId); return Tlv(0x30,Tlv(0x31,Tlv(0x30,Join(new byte[] {6,3,85,4,3},Tlv(12,Encoding.ASCII.GetBytes("pdv-"+agentId)))))); }
    private static byte[] Spki(RSAParameters key) { return Tlv(0x30,Join(RsaAlgorithm,Tlv(3,Join(new byte[] {0},Tlv(0x30,Join(Integer(key.Modulus),Integer(key.Exponent))))))); }
    public static string Sha256(byte[] bytes) { using(SHA256 sha=SHA256.Create()) { return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-",String.Empty).ToLowerInvariant(); } }
    public static string Pem(string label, byte[] bytes) { string body=Convert.ToBase64String(bytes); StringBuilder output=new StringBuilder("-----BEGIN "+label+"-----\r\n"); for(int i=0;i<body.Length;i+=64) output.Append(body.Substring(i,Math.Min(64,body.Length-i))).Append("\r\n"); return output.Append("-----END "+label+"-----\r\n").ToString(); }
    public static byte[] ReadPem(string pem, string label, int maximum) {
      if(pem==null || pem.Length>maximum) throw new InvalidOperationException("RemoteEnrollmentInvalidPem");
      Match match=Regex.Match(pem,"\\A-----BEGIN "+label+"-----\\r?\\n([A-Za-z0-9+/=\\r\\n]+)-----END "+label+"-----(?:\\r?\\n)?\\z");
      if(!match.Success) throw new InvalidOperationException("RemoteEnrollmentInvalidPem");
      try { byte[] bytes=Convert.FromBase64String(match.Groups[1].Value); if(bytes.Length<128) throw new InvalidOperationException(); return bytes; } catch { throw new InvalidOperationException("RemoteEnrollmentInvalidPem"); }
    }
    // Public for offline tests. Production key generation is only GenerateWindows().
    public static PublicRequest CreateRequest(RSA rsa, string agentId, string requestId) {
      AssertId(agentId); AssertId(requestId); if(rsa.KeySize!=2048) throw new InvalidOperationException("RemoteEnrollmentRsa2048Required");
      byte[] spki=Spki(rsa.ExportParameters(false)); byte[] info=Tlv(0x30,Join(new byte[] {2,1,0},Subject(agentId),spki,new byte[] {0xa0,0}));
      byte[] signature;
      using(SHA256 hash=SHA256.Create()) { RSAPKCS1SignatureFormatter formatter=new RSAPKCS1SignatureFormatter(rsa); formatter.SetHashAlgorithm("SHA256"); signature=formatter.CreateSignature(hash.ComputeHash(info)); }
      return new PublicRequest { AgentId=agentId,RequestId=requestId,PublicKeySha256=Sha256(spki),CsrPem=Pem("CERTIFICATE REQUEST",Tlv(0x30,Join(info,Sha256Algorithm,Tlv(3,Join(new byte[] {0},signature))))) };
    }
    // Never returns private material through PowerShell or logging.
    public static PublicRequest GenerateWindows(string keyPath, string agentId, string requestId) {
      if(Environment.OSVersion.Platform!=PlatformID.Win32NT) throw new InvalidOperationException("RemoteEnrollmentWindowsRequired");
      CspParameters parameters=new CspParameters(24,"Microsoft Enhanced RSA and AES Cryptographic Provider"); parameters.Flags=CspProviderFlags.CreateEphemeralKey;
      using(RSACryptoServiceProvider rsa=new RSACryptoServiceProvider(2048,parameters)) {
        rsa.PersistKeyInCsp=false; PublicRequest request=CreateRequest(rsa,agentId,requestId); RSAParameters secret=rsa.ExportParameters(true); byte[] der=null, pem=null;
        try {
          der=Tlv(0x30,Join(new byte[] {2,1,0},Integer(secret.Modulus),Integer(secret.Exponent),Integer(secret.D),Integer(secret.P),Integer(secret.Q),Integer(secret.DP),Integer(secret.DQ),Integer(secret.InverseQ)));
          // Base64 private material is held only inside this method and a protected file.
          pem=Encoding.ASCII.GetBytes(Pem("RSA PRIVATE KEY",der));
          using(FileStream stream=new FileStream(keyPath,FileMode.CreateNew,FileAccess.Write,FileShare.None)) { stream.Write(pem,0,pem.Length); stream.Flush(true); }
          return request;
        } finally {
          if(der!=null) Array.Clear(der,0,der.Length); if(pem!=null) Array.Clear(pem,0,pem.Length);
          Clear(secret.D); Clear(secret.P); Clear(secret.Q); Clear(secret.DP); Clear(secret.DQ); Clear(secret.InverseQ);
        }
      }
    }
    private static void Clear(byte[] bytes) { if(bytes!=null) Array.Clear(bytes,0,bytes.Length); }
    private sealed class Der {
      private readonly byte[] bytes; public int Position; private readonly int end;
      public Der(byte[] data) : this(data,0,data.Length) {}
      private Der(byte[] data,int offset,int length) { bytes=data; Position=offset; end=checked(offset+length); }
      public bool Done { get { return Position==end; } }
      public byte Peek() { if(Position>=end) throw Invalid(); return bytes[Position]; }
      private static Exception Invalid() { return new InvalidOperationException("RemoteEnrollmentInvalidDer"); }
      public byte[] Read(byte expected, bool encoded) {
        int start=Position; if(Position>=end || bytes[Position++]!=expected || Position>=end) throw Invalid();
        int length=bytes[Position++]; if((length&128)!=0) { int count=length&127; if(count==0 || count>3 || Position+count>end || bytes[Position]==0) throw Invalid(); length=0; for(int i=0;i<count;i++) length=checked((length<<8)|bytes[Position++]); if(length<128) throw Invalid(); }
        if(length<0 || Position+length>end) throw Invalid(); int offset=encoded?start:Position; int size=encoded?Position-start+length:length; byte[] result=new byte[size]; Buffer.BlockCopy(bytes,offset,result,0,size); Position+=length; return result;
      }
      public Der Sequence() { return new Der(Read(0x30,false)); }
      public void End() { if(!Done) throw Invalid(); }
    }
    private static bool Equal(byte[] left,byte[] right) { if(left.Length!=right.Length) return false; int different=0; for(int i=0;i<left.Length;i++) different |= left[i]^right[i]; return different==0; }
    private static bool Verify(RSA rsa,byte[] data,byte[] signature) { using(SHA256 hash=SHA256.Create()) { RSAPKCS1SignatureDeformatter verifier=new RSAPKCS1SignatureDeformatter(rsa); verifier.SetHashAlgorithm("SHA256"); return verifier.VerifySignature(hash.ComputeHash(data),signature); } }
    private static RSA ReadRsa(byte[] encoded) {
      Der outer=new Der(encoded); Der spki=outer.Sequence(); outer.End(); if(!Equal(spki.Read(0x30,true),RsaAlgorithm)) throw new InvalidOperationException("RemoteEnrollmentInvalidRsa");
      byte[] bitString=spki.Read(3,false); spki.End(); if(bitString.Length<2 || bitString[0]!=0) throw new InvalidOperationException("RemoteEnrollmentInvalidRsa"); byte[] raw=new byte[bitString.Length-1]; Buffer.BlockCopy(bitString,1,raw,0,raw.Length);
      Der publicOuter=new Der(raw); Der key=publicOuter.Sequence(); publicOuter.End(); byte[] modulus=Unsigned(key.Read(2,false)),exponent=Unsigned(key.Read(2,false)); key.End();
      if(modulus.Length!=256 || (modulus[0]&128)==0 || !Equal(exponent,new byte[] {1,0,1})) throw new InvalidOperationException("RemoteEnrollmentRsa2048Required");
      RSA rsa=RSA.Create(); rsa.ImportParameters(new RSAParameters { Modulus=modulus,Exponent=exponent }); return rsa;
    }
    private static byte[] Unsigned(byte[] integer) { if(integer.Length==0 || (integer[0]&128)!=0 || (integer.Length>1 && integer[0]==0 && (integer[1]&128)==0)) throw new InvalidOperationException("RemoteEnrollmentInvalidDer"); if(integer[0]!=0) return integer; byte[] value=new byte[integer.Length-1]; Buffer.BlockCopy(integer,1,value,0,value.Length); return value; }
    public static string ValidateRequest(string csrPem,string agentId) {
      byte[] bytes=ReadPem(csrPem,"CERTIFICATE REQUEST",8192); Der outer=new Der(bytes); Der request=outer.Sequence(); outer.End(); byte[] infoBytes=request.Read(0x30,true); if(!Equal(request.Read(0x30,true),Sha256Algorithm)) throw new InvalidOperationException("RemoteEnrollmentInvalidCsr"); byte[] signature=request.Read(3,false); request.End();
      Der infoOuter=new Der(infoBytes); Der info=infoOuter.Sequence(); infoOuter.End(); if(!Equal(info.Read(2,false),new byte[] {0}) || !Equal(info.Read(0x30,true),Subject(agentId))) throw new InvalidOperationException("RemoteEnrollmentInvalidCsr"); byte[] spki=info.Read(0x30,true); if(info.Read(0xa0,false).Length!=0) throw new InvalidOperationException("RemoteEnrollmentInvalidCsr"); info.End();
      if(signature.Length!=257 || signature[0]!=0) throw new InvalidOperationException("RemoteEnrollmentInvalidCsr"); byte[] raw=new byte[signature.Length-1]; Buffer.BlockCopy(signature,1,raw,0,raw.Length); using(RSA rsa=ReadRsa(spki)) { if(!Verify(rsa,infoBytes,raw)) throw new InvalidOperationException("RemoteEnrollmentInvalidCsr"); } return Sha256(spki);
    }
    private static byte[] CertificateSpki(byte[] tbs,string agentId) {
      Der outer=new Der(tbs); Der certificate=outer.Sequence(); outer.End(); if(certificate.Peek()==0xa0) { Der version=new Der(certificate.Read(0xa0,false)); if(!Equal(version.Read(2,false),new byte[] {2})) throw new InvalidOperationException("RemoteEnrollmentInvalidCertificate"); version.End(); }
      certificate.Read(2,false); if(!Equal(certificate.Read(0x30,true),Sha256Algorithm)) throw new InvalidOperationException("RemoteEnrollmentInvalidCertificate"); certificate.Read(0x30,true); certificate.Read(0x30,true); if(!Equal(certificate.Read(0x30,true),Subject(agentId))) throw new InvalidOperationException("RemoteEnrollmentCertificateIdentityMismatch"); return certificate.Read(0x30,true);
    }
    private static byte[][] CertificateChain(string chain) {
      if(chain==null || chain.Length>32768) throw new InvalidOperationException("RemoteEnrollmentInvalidPem");
      List<byte[]> certificates=new List<byte[]>(); int cursor=0;
      foreach(Match match in Regex.Matches(chain,"-----BEGIN CERTIFICATE-----\\r?\\n[A-Za-z0-9+/=\\r\\n]+-----END CERTIFICATE-----(?:\\r?\\n)?")) {
        if(chain.Substring(cursor,match.Index-cursor).Trim().Length!=0 || certificates.Count>=2) throw new InvalidOperationException("RemoteEnrollmentInvalidChain");
        certificates.Add(ReadPem(match.Value,"CERTIFICATE",16384)); cursor=match.Index+match.Length;
      }
      if(certificates.Count<1 || chain.Substring(cursor).Trim().Length!=0) throw new InvalidOperationException("RemoteEnrollmentInvalidChain"); return certificates.ToArray();
    }
    private static byte[] VerifySignedCertificate(byte[] raw,X509Certificate2 issuer) {
      Der outer=new Der(raw); Der signed=outer.Sequence(); outer.End(); byte[] tbs=signed.Read(0x30,true);
      if(!Equal(signed.Read(0x30,true),Sha256Algorithm)) throw new InvalidOperationException("RemoteEnrollmentInvalidCertificate");
      byte[] signature=signed.Read(3,false); signed.End(); if(signature.Length<2 || signature[0]!=0) throw new InvalidOperationException("RemoteEnrollmentInvalidCertificate");
      byte[] signatureBytes=new byte[signature.Length-1]; Buffer.BlockCopy(signature,1,signatureBytes,0,signatureBytes.Length);
      Der tbsOuter=new Der(tbs); Der content=tbsOuter.Sequence(); tbsOuter.End(); if(content.Peek()==0xa0) content.Read(0xa0,false); content.Read(2,false);
      if(!Equal(content.Read(0x30,true),Sha256Algorithm) || !Equal(content.Read(0x30,true),issuer.SubjectName.RawData)) throw new InvalidOperationException("RemoteEnrollmentInvalidIssuer");
      using(RSA caKey=issuer.PublicKey.Key as RSA) { if(caKey==null || caKey.KeySize<2048 || !Verify(caKey,tbs,signatureBytes)) throw new InvalidOperationException("RemoteEnrollmentCertificateSignatureInvalid"); }
      return tbs;
    }
    private static void AssertValidity(X509Certificate2 certificate,DateTime nowUtc,X509Certificate2 issuer) {
      if(certificate.NotBefore.ToUniversalTime()>nowUtc || certificate.NotAfter.ToUniversalTime()<=nowUtc || (issuer!=null && certificate.NotAfter>issuer.NotAfter)) throw new InvalidOperationException("RemoteEnrollmentCertificateValidity");
    }
    private static void AssertAuthority(X509Certificate2 certificate,bool intermediate) {
      bool basic=false,usage=false;
      foreach(X509Extension extension in certificate.Extensions) {
        if(extension.Oid.Value=="2.5.29.19") {
          X509BasicConstraintsExtension constraints=new X509BasicConstraintsExtension(extension,extension.Critical);
          if(basic || !constraints.CertificateAuthority || !extension.Critical || (intermediate && (!constraints.HasPathLengthConstraint || constraints.PathLengthConstraint!=0))) throw new InvalidOperationException("RemoteEnrollmentInvalidIssuer"); basic=true;
        } else if(extension.Oid.Value=="2.5.29.15") {
          X509KeyUsageExtension keyUsage=new X509KeyUsageExtension(extension,extension.Critical);
          X509KeyUsageFlags allowed=X509KeyUsageFlags.KeyCertSign|X509KeyUsageFlags.CrlSign;
          if(usage || (keyUsage.KeyUsages & X509KeyUsageFlags.KeyCertSign)==0 || (keyUsage.KeyUsages & ~allowed)!=0) throw new InvalidOperationException("RemoteEnrollmentInvalidIssuer"); usage=true;
        } else if(extension.Oid.Value=="2.5.29.37") {
          X509EnhancedKeyUsageExtension enhanced=new X509EnhancedKeyUsageExtension(extension,extension.Critical);
          if(enhanced.EnhancedKeyUsages.Count!=1 || enhanced.EnhancedKeyUsages[0].Value!="1.3.6.1.5.5.7.3.2") throw new InvalidOperationException("RemoteEnrollmentInvalidIssuer");
        } else if(extension.Critical) throw new InvalidOperationException("RemoteEnrollmentUnknownCriticalExtension");
      }
      if(!basic || !usage) throw new InvalidOperationException("RemoteEnrollmentInvalidIssuer");
    }
    public static IssuedCertificate ValidateCertificate(string certificatePem,string issuerCaPem,string issuerCaSha256,string agentId,string publicKeySha256,DateTime nowUtc) {
      AssertId(agentId); if(!Regex.IsMatch(issuerCaSha256??String.Empty,"\\A[a-f0-9]{64}\\z") || !Regex.IsMatch(publicKeySha256??String.Empty,"\\A[a-f0-9]{64}\\z")) throw new InvalidOperationException("RemoteEnrollmentInvalidPin");
      byte[][] chain=CertificateChain(certificatePem); byte[] raw=chain[0],caRaw=ReadPem(issuerCaPem,"CERTIFICATE",16384);
      if(Sha256(caRaw)!=issuerCaSha256) throw new InvalidOperationException("RemoteEnrollmentIssuerPinMismatch");
      X509Certificate2 intermediate=null;
      try {
        using(X509Certificate2 leaf=new X509Certificate2(raw)) using(X509Certificate2 root=new X509Certificate2(caRaw)) {
          AssertValidity(root,nowUtc,null); AssertAuthority(root,false);
          X509Certificate2 issuer=root;
          if(chain.Length==2) { foreach(X509Extension extension in root.Extensions) { if(extension.Oid.Value=="2.5.29.19") { X509BasicConstraintsExtension constraints=new X509BasicConstraintsExtension(extension,extension.Critical); if(constraints.HasPathLengthConstraint && constraints.PathLengthConstraint<1) throw new InvalidOperationException("RemoteEnrollmentIssuerPathLength"); } } intermediate=new X509Certificate2(chain[1]); AssertValidity(intermediate,nowUtc,root); AssertAuthority(intermediate,true); VerifySignedCertificate(chain[1],root); issuer=intermediate; }
          AssertValidity(leaf,nowUtc,issuer); if(leaf.NotAfter.ToUniversalTime()>nowUtc.AddDays(398)) throw new InvalidOperationException("RemoteEnrollmentCertificateValidity");
          bool basic=false,usage=false,eku=false;
          foreach(X509Extension extension in leaf.Extensions) {
            if(extension.Oid.Value=="2.5.29.19") { X509BasicConstraintsExtension constraints=new X509BasicConstraintsExtension(extension,extension.Critical); if(constraints.CertificateAuthority || basic) throw new InvalidOperationException("RemoteEnrollmentInvalidCertificate"); basic=true; }
            else if(extension.Oid.Value=="2.5.29.15") { X509KeyUsageExtension keyUsage=new X509KeyUsageExtension(extension,extension.Critical); if(keyUsage.KeyUsages!=X509KeyUsageFlags.DigitalSignature || usage) throw new InvalidOperationException("RemoteEnrollmentInvalidCertificate"); usage=true; }
            else if(extension.Oid.Value=="2.5.29.37") { X509EnhancedKeyUsageExtension enhanced=new X509EnhancedKeyUsageExtension(extension,extension.Critical); if(enhanced.EnhancedKeyUsages.Count!=1 || enhanced.EnhancedKeyUsages[0].Value!="1.3.6.1.5.5.7.3.2" || eku) throw new InvalidOperationException("RemoteEnrollmentInvalidCertificate"); eku=true; }
            else if(extension.Critical) throw new InvalidOperationException("RemoteEnrollmentUnknownCriticalExtension");
          }
          if(!basic || !usage || !eku) throw new InvalidOperationException("RemoteEnrollmentInvalidCertificate");
          byte[] tbs=VerifySignedCertificate(raw,issuer); string actualPublic=Sha256(CertificateSpki(tbs,agentId));
          if(actualPublic!=publicKeySha256) throw new InvalidOperationException("RemoteEnrollmentCertificateKeyMismatch");
          return new IssuedCertificate { CertificateSha256=Sha256(raw),PublicKeySha256=actualPublic,NotAfter=leaf.NotAfter.ToUniversalTime().ToString("o") };
        }
      } finally { if(intermediate!=null) intermediate.Dispose(); }
    }
  }
}
