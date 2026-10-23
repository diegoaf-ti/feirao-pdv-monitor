"""Offline ephemeral test fixtures only. Never reads production PKI; requires OpenSSL 3."""
import pathlib
import subprocess
import sys

def run(*args):
    subprocess.run(['openssl', *map(str, args)], check=True, capture_output=True)

def create(path):
    root = pathlib.Path(path)
    root.mkdir(mode=0o700, exist_ok=True)
    root.chmod(0o700)
    ca_ext = root / 'root-ext.cnf'
    ca_ext.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=Ephemeral test root\n[ext]\nbasicConstraints=critical,CA:TRUE,pathlen:1\nkeyUsage=critical,keyCertSign,cRLSign\n')
    run('req','-new','-x509','-newkey','rsa:2048','-noenc','-keyout',root/'root.key','-out',root/'root.crt','-days','390','-sha256','-config',ca_ext)
    run('req','-new','-newkey','rsa:2048','-noenc','-keyout',root/'intermediate.key','-out',root/'intermediate.csr','-subj','/CN=Ephemeral online intermediate','-sha256')
    intermediate_ext = root/'intermediate-ext.cnf'
    intermediate_ext.write_text('basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n')
    run('x509','-req','-in',root/'intermediate.csr','-CA',root/'root.crt','-CAkey',root/'root.key','-set_serial','2','-days','365','-sha256','-extfile',intermediate_ext,'-out',root/'intermediate.crt')
    for name,ca,eku,usage in [('leaf','intermediate','clientAuth','digitalSignature'),('direct','root','clientAuth','digitalSignature'),('server','intermediate','serverAuth','digitalSignature'),('extra','intermediate','clientAuth','digitalSignature,keyEncipherment')]:
        ext=root/f'{name}-ext.cnf'
        ext.write_text(f'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,{usage}\nextendedKeyUsage={eku}\n')
        run('x509','-req','-in',root/'request.csr','-CA',root/f'{ca}.crt','-CAkey',root/f'{ca}.key','-set_serial',str(10+len(name)),'-days','90','-sha256','-extfile',ext,'-out',root/f'{name}.crt')
if __name__ == '__main__':
    create(sys.argv[1])
