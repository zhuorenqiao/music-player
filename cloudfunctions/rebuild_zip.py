import zipfile, shutil, os, base64

src = 'current-function.zip'
new_index = 'lyrics-relay-package/index.js'
bootstrap = 'lyrics-relay-package/scf_bootstrap'
out = 'lyrics-relay-v2.zip'

old = zipfile.ZipFile(src)
boot_info = old.getinfo('scf_bootstrap')

with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    zi = zipfile.ZipInfo('index.js')
    zi.create_system = 0
    zi.create_version = 20
    zi.extract_version = 20
    zi.external_attr = 0
    zi.date_time = (1980, 1, 1, 0, 0, 0)
    zi.compress_type = zipfile.ZIP_DEFLATED
    with open(new_index, 'rb') as f:
        z.writestr(zi, f.read())

    zi = zipfile.ZipInfo('scf_bootstrap')
    zi.create_system = boot_info.create_system
    zi.create_version = boot_info.create_version
    zi.extract_version = boot_info.extract_version
    zi.external_attr = boot_info.external_attr
    zi.date_time = boot_info.date_time
    zi.extra = boot_info.extra
    zi.compress_type = zipfile.ZIP_DEFLATED
    with open(bootstrap, 'rb') as f:
        z.writestr(zi, f.read())

z = zipfile.ZipFile(out)
print('testzip', z.testzip())
for i in z.infolist():
    print(i.filename, i.create_version, i.create_system, oct(i.external_attr >> 16), i.extra)
print('zip', os.path.getsize(out), 'b64', len(base64.b64encode(open(out, 'rb').read()).decode()))
with open(out + '.b64', 'w') as f:
    f.write(base64.b64encode(open(out, 'rb').read()).decode())
