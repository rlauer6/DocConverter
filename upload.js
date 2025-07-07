// ---------------------------------------------------------------------
// Wake up the converter on page load
$(function () {
    $.get('/converter/wake-up', () => {
        console.log('Converter woken up.');
    });

    $('#tags').tagsInput({
      'defaultText': 'add a tag',
      'width': '300px',
      'height': 'auto',
      'interactive': true,
      'delimiter': ',',
      'removeWithBackspace': true,
      'minChars': 1
    });

    $(document).on('keypress', '.tagsinput input', function(e) {
        if (e.which === 13) { // Enter key
            e.preventDefault(); // prevent form submit or newline
            const val = $(this).val();
            if (val.length > 0) {
                $(this).closest('.tagsinput').prev().addTag(val);
                $(this).val('');
            }
        }
    });

    // ---------------------------------------------------------------------
    $('#upload-form').on('submit', function (e) {
        e.preventDefault();

        const fileInput = $('input[name="upload"]')[0];
        const file = fileInput.files[0];
        if (!file) return;

        const formData = new FormData();
        formData.append('upload', file);

        const $row = $(`
        <div class="file-row">
          <strong>${file.name}</strong>
          <button disabled>Download</button>
          <div class="spinner"></div>
          <div class="metadata"></div>
        </div>
      `);
        $('#uploads').append($row);

        const $button = $row.find('button');
        const $spinner = $row.find('.spinner');
        const $meta = $row.find('.metadata');

        const action = $('#action').is(':checked') ? 'pdf' : '';

        var tags = encodeURIComponent($('#tags').val());
        console.log(tags);

        var thumbnails = $('#thumbnails').is(':checked') ? 1 : 0;
        let query = '?action=' + action + '&tags=' + tags + '&thumbnails=' + thumbnails;

        $.ajax({
            url: `/converter${query}`,
            type: 'POST',
            data: formData,
            processData: false,
            contentType: false,
            success: function (resp) {
                const documentId = resp.document_id;
                pollStatus(documentId, $row, $button, $spinner, $meta);
            },
            error: function () {
                $spinner.remove();
                $row.append('<div style="color:red;">Upload failed.</div>');
            }
        });
    });
});


function pollStatus(documentId, $row, $button, $spinner, $meta) {
    const url = `/converter/${documentId}/status`;
    const start = Date.now();
    const timeout = 20000; // 20 seconds

    function doPoll() {
        const elapsed = Date.now() - start;
        if (elapsed >= timeout) {
            $spinner.remove();
            $row.append('<div style="color: orange;">Timed out waiting for conversion.</div>');
            return;
        }

        $.getJSON(url, function (statusResp) {
            console.log(statusResp);

            if (statusResp.status === 'complete') {
                $spinner.remove();

                const data = statusResp.data;
                const error = data.error;

                if (error) {
                    $meta.html(`<div style="color: red;"><strong>Error:</strong> ${error}</div>`);
                    return; // don't enable the button or attach the download link
                }

                $button.prop('disabled', false);

                const pdf = data.pdf || {};
                const t = (data.conversion_time && data.conversion_time.t) || {};
                const thumb = 'thumbs' in data ? data.thumbs.thumbnail.tag : '';
                const html = `
                  <div><strong>Document ID:</strong> ${data.document_id}</div>
                  <div><strong>Elapsed Time:</strong> ${t.elapsed_time ?? 'N/A'} s</div>
                  <div><strong>Pages:</strong> ${pdf.pages ?? 'N/A'}</div>
                  <div><strong>Size:</strong> ${pdf.size ?? 'N/A'} bytes</div>
                  <div>${thumb}</div>
                `;

                $meta.html(html);

                $button.on('click', function () {
                    window.location.href = `/converter/${documentId}`;
                });
            } else {
                setTimeout(doPoll, 2000);
            }
        }).fail(function () {
            $spinner.remove();
            $row.append('<div style="color:red;">Polling failed.</div>');
        });
    }

    doPoll();
}
