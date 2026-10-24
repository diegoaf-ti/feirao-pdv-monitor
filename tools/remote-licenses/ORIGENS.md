# Origens e licenças dos componentes

UltraVNC 1.8.3.0: GPL-3.0-or-later. Distribuição oficial: https://uvnc.com/downloads/ultravnc/172-ultravnc-1-8-3-0.html . A revisão oficial identificada como 1.8.3.0 é 36c2389f681c9c939d5276323cf6242d26bb00fb, de 20/09/2026: https://github.com/ultravnc/UltraVNC/commit/36c2389f681c9c939d5276323cf6242d26bb00fb . Código dessa revisão: https://github.com/ultravnc/UltraVNC/archive/36c2389f681c9c939d5276323cf6242d26bb00fb.tar.gz . Para redistribuição externa, manter acesso equivalente ao código correspondente junto ao download do monitor; o projeto não oferece tags/releases no GitHub. O commit 92bb19b9eb01b043bf84172dfa493cd7b9341076 foi usado somente para conferir o algoritmo VNC.

stunnel 5.82: GPL-2.0-or-later com exceção de ligação OpenSSL. Fontes exatas: https://www.stunnel.org/downloads/stunnel-5.82.tar.gz (SHA-256: 8e7438ccd6b3a2ab05182d0846e112a56a7f557ecdee40de07bf67820008bef7). Os textos stunnel-COPYING.md e stunnel-GPL-2.md vêm desse tarball.

OpenSSL no instalador stunnel: 3.5.8; Apache-2.0. Texto da licença da série oficial 3.5: https://github.com/openssl/openssl/blob/openssl-3.5.9/LICENSE.txt . Fontes da série: https://openssl-library.org/source/old/3.5/ .

libssp-0.dll é runtime GCC, GPL-3.0 com GCC Runtime Library Exception 3.1. Textos obtidos do repositório oficial GCC: https://github.com/gcc-mirror/gcc/tree/releases/gcc-16.2.0 . Proveniência binária: somente o instalador oficial stunnel 5.82 assinado, com hash fixado.

Este bundle não incorpora drivers virtuais, viewer, repeater, plugins DSM, perfil ativo, senhas ou chaves privadas. As licenças não substituem validação Authenticode, teste de interoperabilidade nem acompanhamento dos avisos dos fornecedores.
