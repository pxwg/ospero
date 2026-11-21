;;; -*- lexical-binding: t; -*-
(require 'ox-html)
(require 'org-id)
(require 'subr-x)

(defvar reader-dir (file-name-directory (or load-file-name buffer-file-name)))
(defvar reader-root (expand-file-name "../" reader-dir))
(defvar reader-cards (make-hash-table :test 'equal))
(defvar reader-blocks (make-hash-table :test 'equal))
(defvar reader-titles (make-hash-table :test 'equal))

(defun reader-read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun reader-link (link description info)
  (let ((id (org-element-property :path link))
        (kind (org-element-property :type link)))
    (cond
     ((equal kind "id")
      (unless (gethash id reader-titles) (error "Missing card %s" id))
      (format "<a href=\"#stack=%s\" data-card=\"%s\">%s</a>" id id (or description (org-html-encode-plain-text (gethash id reader-titles)))))
     ((equal kind "include")
      (let ((body (gethash id reader-cards)))
        (unless body (error "Missing transclusion %s" id))
        (format "<details class=\"tree\"><summary>%s</summary>%s</details>"
                (or description (org-html-encode-plain-text (gethash id reader-titles))) body)))
     (t (org-html-link link description info)))))

(defun reader-code (block _contents info)
  (let* ((args (org-babel-parse-header-arguments (org-element-property :parameters block) t))
         (id (cdr (assq :id args)))
         (label (or (cdr (assq :target-file args)) id "代码"))
         (html (org-html-src-block block nil info)))
    (when (equal (cdr (assq :zk-noweb args)) "yes")
      (setq html
            (replace-regexp-in-string
             "&lt;&lt;\\([a-zA-Z0-9_-]+\\)&gt;&gt;"
             (lambda (literal)
               (let* ((ref (match-string 1 literal))
                      (owner (gethash ref reader-blocks)))
                 (unless owner (error "Missing code block %s" ref))
                 (format "<a href=\"#stack=%s&amp;block=%s\" data-card=\"%s\" data-block=\"%s\">%s</a>"
                         owner ref owner ref literal)))
             html t t)))
    (format "<details class=\"code\" data-block=\"%s\"><summary>%s</summary>%s</details>"
            (or id "") (org-html-encode-plain-text label) html)))

(org-link-set-parameters "include")
(org-export-define-derived-backend 'ospero-reader 'html
  :translate-alist '((link . reader-link) (src-block . reader-code)))
(defun reader-render (text)
  (let ((org-export-use-babel nil) (org-html-htmlize-output-type nil)
        (org-export-with-sub-superscripts nil) (org-export-with-smart-quotes nil))
    (org-export-string-as text 'ospero-reader t '(:with-toc nil :section-numbers nil))))

(let ((files (directory-files-recursively (expand-file-name "notes" reader-root) "\\.org\\'"))
      records)
  (dolist (file files)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (unless (looking-at "\\* \\(.*\\)\n:PROPERTIES:\n:ID: \\([a-zA-Z0-9_./-]+\\)\n:END:\n")
        (error "Missing card header in %s" file))
      (let ((title (match-string 1)) (id (match-string 2)) (start (match-end 0)))
        (when (gethash id reader-titles) (error "Duplicate card %s" id))
        (puthash id title reader-titles)
        (while (re-search-forward "^#\\+begin_src [^\n]*? :id \\([a-zA-Z0-9_-]+\\)" nil t)
          (puthash (match-string 1) id reader-blocks))
        (push (cons id (buffer-substring-no-properties start (point-max))) records))))
  (dolist (record records)
    (puthash (car record) (reader-render (cdr record)) reader-cards))
  (let* ((source (reader-read (expand-file-name "index.org" reader-root)))
         (title (and (string-match "^#\\+title: \\(.*\\)$" source) (match-string 1 source)))
         (home (reader-render source)))
    (with-temp-file (expand-file-name "index.html" reader-root)
      (insert "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>"
              title " · Ospero</title><style>" (reader-read (expand-file-name "reader.css" reader-dir))
              "</style><body><header class=\"zk-bar\"><a href=\"#\" aria-label=\"回到导览\">Ospero</a>文学编程笔记</header>"
              "<main class=\"zk-stack\"><section class=\"zk-pane\" data-node=\"home\"><article><h1>" title "</h1>" home "</article></section></main>")
      (dolist (record (reverse records))
        (let ((id (car record)))
          (insert "<template data-id=\"" id "\"><article><h1>"
                  (org-html-encode-plain-text (gethash id reader-titles))
                  "</h1>" (gethash id reader-cards) "</article></template>")))
      (insert "<script>" (reader-read (expand-file-name "reader.js" reader-dir))
              "</script></body></html>"))))
