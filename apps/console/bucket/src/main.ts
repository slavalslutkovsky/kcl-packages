// Standalone: `nx serve console-bucket` renders the page without the host.
import { mount } from './mfe';

const root = document.getElementById('root');
if (!root) throw new Error('#root element missing from index.html');
void mount({ name: '@shluviza/bucket', domElement: root, apiBase: '', basePath: '/', navigate: (to) => location.assign(to) });
