# Habilitar HTTPS (nginx/apache) -> HTTP testlink

Copiar arquivo php configCheck.php
``` shell
# Copiar arquivo do container para local
docker cp 9622c928e051:/opt/bitnami/testlink/lib/functions/configCheck.php .

#Editar arquivo local
vim configCheck.php
```

Editar funcao para forçar uso do HTTPS.
Procurar função: `function get_home_url($opt)`

Achar final da função na linha: `$t_url  = $t_protocol . '://' . $t_host . $t_path.'/';`

Adicionar a linha abaixo `$t_protocol='https';`

A função deverá ficar com a seguir:
``` php
...
$t_protocol='https';
$t_url  = $t_protocol . '://' . $t_host . $t_path.'/';
return ($t_url);
}
...
```

Copiar arquivo de volta para container e reiniciar:
```shell
docker cp configCheck.php 9622c928e051:/opt/bitnami/testlink/lib/functions/configCheck.php
docker restart 9622c928e051
```