<?php header('Access-Control-Allow-Origin: *'); ?>
<html lang="en">

<head>
    <title>Title</title>
    <!-- Required meta tags -->
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">

    <!-- Bootstrap CSS -->
    <link rel="stylesheet" href="https://stackpath.bootstrapcdn.com/bootstrap/4.3.1/css/bootstrap.min.css" integrity="sha384-ggOyR0iXCbMQv3Xipma34MD+dH/1fQ784/j6cY/iJTQUOhcWr7x9JvoRxT2MZw1T" crossorigin="anonymous">
</head>

<body>

    <div class="jumbotron jumbotron-fluid">
        <div class="container">
            <h1 class="display-3">Fluid jumbo heading</h1>
            <p class="lead">Jumbo helper text</p>
            <hr class="my-2">
            <p>More info</p>
            <p class="lead">
                <a class="btn btn-primary btn-lg" href="Jumbo action link" role="button">Jumbo action name</a>
            </p>
            <table class="table Wid100">
                <tbody>
                    <tr>
                        <td scope="row"></td>
                        <td><iframe id="frame1" src="" width="450" height="200" frameborder="0"></iframe></td>
                        <td><iframe id="frame2" src="" width="450" height="200" frameborder="0"></iframe></td>
                    </tr>
                </tbody>
            </table>
        </div>
    </div>

    <!-- Optional JavaScript -->
    <!-- jQuery first, then Popper.js, then Bootstrap JS -->
    <script src="https://code.jquery.com/jquery-3.5.1.js" integrity="sha256-QWo7LDvxbWT2tbbQ97B53yJnYU3WhH/C8ycbRAkjPDc=" crossorigin="anonymous"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.14.7/umd/popper.min.js" integrity="sha384-UO2eT0CpHqdSJQ6hJty5KVphtPhzWj9WO1clHTMGa3JDZwrnQq4sF86dIHNDz0W1" crossorigin="anonymous"></script>
    <script src="https://stackpath.bootstrapcdn.com/bootstrap/4.3.1/js/bootstrap.min.js" integrity="sha384-JjSmVgyd0p3pXB1rRibZUAYoIIy6OrQ6VrjIEaFf/nJGzIxFDsf4x0xIM+B07jRM" crossorigin="anonymous"></script>

    <script>
        $(function() {
            console.log('documento ready');

            loadIframe('http://localhost:3000/d-solo/NSQveVpMk/employees-dashboard?orgId=1&refresh=5s&from=1603237523716&to=1603259123716&panelId=4', 'frame1');
            loadIframe('http://localhost:3000/d-solo/NSQveVpMk/employees-dashboard?orgId=1&refresh=5s&from=1603237714834&to=1603259314834&panelId=2', 'frame2');

        });

        function loadIframe(url, frameId) {
            console.log('load iframe: ' + url);
            $.ajax({
                type: "POST",
                url: url,
                crossDomain: false,
                headers: {
                    'Access-Control-Allow-Origin': '*',
                    "Authorization": "Bearer eyJrIjoiTjdiQ2ZPUTNaR243VmZrVnliZjFYeVlMMnJPUkJ1dnQiLCJuIjoiZW1wbG95ZWVzX2Rhc2giLCJpZCI6MX0="
                },
                success: function(data) {
                    var frame = "#" + frameId;
                    $(frame).attr('src', "/")
                    $(frame).contents().find('html').html(data);
                }
            });
        }
    </script>
</body>

</html>