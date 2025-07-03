// ---------------------------------------------------------------------
// Wake up the converter on page load
$(function () {
    $.get('/converter/wake-up', () => {
        console.log('Converter woken up.');
    });

    $('#create-preview').on('change', function () {
        const enabled = this.checked;
        $('#preview-height').prop('disabled', !enabled);
        $('#preview-width').prop('disabled', !enabled);
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
          <button disabled>Download PDF</button>
          <div class="spinner"></div>
          <div class="metadata"></div>
        </div>
      `);
        $('#uploads').append($row);

        const $button = $row.find('button');
        const $spinner = $row.find('.spinner');
        const $meta = $row.find('.metadata');

        const action = $('#action').is(':checked') ? 'pdf' : '';
        let query = '';

        if ($('#create-preview').is(':checked')) {
            var h = $('#preview-height').val();
            if (! h ) {
                h = 100;
            }
            var w = $('#preview-width').val();
            if ( ! w ) {
                w = '';
            }
            var thumb = `${h}x${w}`;
            query = `?action=${action}&thumb=${thumb}`;
        }

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
    const url = `/converter/status/${documentId}`;
    const start = Date.now();
    const timeout = 15000; // 15 seconds

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

                const html = `
                  <div><strong>Document ID:</strong> ${data.document_id}</div>
                  <div><strong>Elapsed Time:</strong> ${t.elapsed_time ?? 'N/A'} s</div>
                  <div><strong>Pages:</strong> ${pdf.pages ?? 'N/A'}</div>
                  <div><strong>Size:</strong> ${pdf.size ?? 'N/A'} bytes</div>
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
