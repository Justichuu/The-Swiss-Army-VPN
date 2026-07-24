function renderBreadcrumb(path = '') {
    const breadcrumb = document.getElementById('breadcrumb');
    const segments = path ? path.split('/').filter(Boolean) : [];

    if (!segments.length) {
        breadcrumb.innerHTML = '<div class="breadcrumb-root">/</div>';
        return;
    }

    const crumbs = segments.map((segment, index) => {
        const targetPath = segments.slice(0, index + 1).join('/');
        return `<button data-path="${targetPath}" class="breadcrumb-link">${segment}</button>`;
    });

    breadcrumb.innerHTML = `<button data-path="" class="breadcrumb-link">root</button> / ${crumbs.join(' / ')}`;
    breadcrumb.querySelectorAll('button').forEach(button => {
        button.addEventListener('click', () => listDirectory(button.dataset.path));
    });
}

async function listDirectory(path = '') {
    const fileList = document.getElementById('fileList');
    fileList.innerHTML = '<p style="color: #9cc3ff;">Loading...</p>';

    try {
        const response = await fetch(`/api/files?path=${encodeURIComponent(path)}`);
        if (!response.ok) throw new Error('Failed to load directory');

        const data = await response.json();
        fileList.innerHTML = '';
        renderBreadcrumb(path);

        if (!data.items.length) {
            fileList.innerHTML = '<p style="color: #ccc;">This directory is empty.</p>';
            return;
        }

        data.items.forEach(item => {
            const link = document.createElement('a');
            link.className = `file-item ${item.type === 'directory' ? 'folder' : 'file'}`;
            const normalizedPath = path ? (path.endsWith('/') ? path : `${path}/`) : '';
            const targetPath = `${normalizedPath}${item.name}`;
            const encodedPath = targetPath.split('/').map(encodeURIComponent).join('/');
            link.href = item.type === 'directory'
                ? `/${encodedPath}/`
                : `/${encodedPath}?raw=1`;

            const nameSpan = document.createElement('div');
            nameSpan.className = 'file-name';
            nameSpan.textContent = item.name;

            const typeSpan = document.createElement('div');
            typeSpan.className = 'file-type';
            typeSpan.textContent = item.type === 'directory' ? '📁 Folder' : `📄 ${item.name.split('.').pop()}`;

            link.appendChild(nameSpan);
            link.appendChild(typeSpan);
            fileList.appendChild(link);
        });
    } catch (error) {
        console.error('Error:', error);
        fileList.innerHTML = '<p style="color: #f44336;">⚠️ Error loading files. Make sure the server is running.</p>';
    }
}

const currentPath = decodeURIComponent(window.location.pathname === '/' ? '' : window.location.pathname.slice(1));
document.getElementById('port').textContent = window.location.port || '80';
const repoLink = document.getElementById('repoLink');
if (repoLink) {
    repoLink.href = 'https://github.com/Justichuu/The-Swiss-Army-VPN';
}
listDirectory(currentPath);
